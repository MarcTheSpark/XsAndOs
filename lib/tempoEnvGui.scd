// ============================================================================
// tempoEnvGui.scd  --  a GUI to draw per-cue tempo curves (BPM over beats).
//
// Loaded once by midi_cue_player.scd (this.executeFile ...). Opens with
//   ~tempoGui.value
// Built on the core EnvelopeView. The envelope ALWAYS spans the full cue: the
// x axis is the cue's length in beats with the first node pinned at the left and
// the last node pinned at the right. The y axis is BPM; its range is shown by the
// two boxes at the top-right / bottom-right of the graph (auto-fit on load,
// editable). Drag nodes to shape the curve, pick a curve type per segment,
// add/remove interior nodes, audition, and save to ~tempoEnvPath.
//
// Edits write straight into ~tempoEnvs[cueName], so ~play / ~next pick them up
// immediately. Numbers are kept to 2-decimal precision.
//
// Must stay ONE compilation unit (it is executeFile'd as a whole).
// ============================================================================
(
~tgCurveTypes = [\lin, \exp, \sin, \wel, \sqr, \cub, \hold, \step];

// A cue's length in beats = its window length, or its last note end for whole-file cues.
~cueBeatLength = { |cue|
	var len = cue[\endBeat] - cue[\startBeat];
	if((len == inf) or: { len <= 0 }) {
		len = if(cue[\notes].isEmpty) { 4 } { cue[\notes].collect({ |n| n[\startBeat] + n[\durBeats] }).maxItem };
	};
	len.max(0.001);
};

// A padded, rounded BPM range that comfortably contains the envelope.
~tgAutoRange = { |bpms|
	var lo = bpms.minItem, hi = bpms.maxItem;
	var pad = ((hi - lo) * 0.2).max(10);
	[ (lo - pad).max(1).round(1), (hi + pad).round(1) ];
};

// Env <-> editor model (model = (beats:, bpms:, curves:); beats absolute from 0;
// one curve per segment = beats.size - 1).
~tgEnvToModel = { |env|
	var durs   = env.times;
	var curves = env.curves;
	var beats  = [0];
	durs.do({ |d| beats = beats.add(beats.last + d) });
	if(curves.isArray.not) { curves = Array.fill(durs.size.max(1), curves) };
	(beats: beats, bpms: env.levels, curves: curves);
};

// floor clamps the levels (tempo needs BPM >= 1; params use their own range low,
// which may be 0 or negative). The model field is named \bpms for historical
// reasons but holds generic y-values (BPM for tempo, param value otherwise).
~tgModelToEnv = { |m, floor = 1|
	var beats = m[\beats];
	var durs  = (1 .. (beats.size - 1)).collect({ |i| (beats[i] - beats[i - 1]).max(0.001).round(0.01) });
	Env(m[\bpms].collect({ |v| v.max(floor).round(0.01) }), durs, m[\curves]);
};

~openTempoEnvGui = {
	var win, env, graph, cueMenu, trackMenu, paramMenu, curveMenu, curveNumBox, addBtn, remBtn, audBtn, saveBtn, info;
	var minBpmBox, maxBpmBox, yLabel;
	var minBPM = 40, maxBPM = 240, cueLen = 16;
	var currentName, model, names, updating = false;
	var curParam = \tempo, curTrack = "*", trackItems, paramItems;
	var refresh, readView, loadCue, updateInfo, syncCurveMenu;
	var storeEnv, getEnv, yFloor, defaultModel;

	names = ~cues.collect({ |c| c[\name] });

	// The editor edits one (cue, track, param) curve at a time. param \tempo is the
	// per-cue tempo curve in ~tempoEnvs (track ignored); every other param is a
	// (cue, track, param) curve in ~paramEnvs. These three helpers hide which dict.
	storeEnv = { |e|
		if(curParam == \tempo) { ~tempoEnvs[currentName] = e }
		{ ~paramEnvs[~paramKey.(currentName, curTrack, curParam)] = e };
	};
	getEnv = {
		if(curParam == \tempo) { ~tempoEnvs[currentName] }
		{ ~paramEnvs[~paramKey.(currentName, curTrack, curParam)] };
	};
	yFloor = { if(curParam == \tempo) { 1 } { ~paramRanges[curParam][0] } };
	// A brand-new curve sits flat on the synth's declared default for this control
	// (introspected from the track's SynthDef), so an untouched param curve is a
	// no-op vs. not drawing one. Tempo has no synth default, so it starts at 120.
	defaultModel = {
		var v = if(curParam == \tempo) { 120 }
		        { ~paramCurveDefault.(currentName, curTrack, curParam) };
		(beats: [0, cueLen], bpms: [v, v], curves: [\lin]);
	};

	// track menu lists every track index actually present in the cues, plus "*";
	// param menu is tempo + the engine's ~paramList.
	trackItems = ["*"] ++ ~cues.collect({ |c| c[\notes].collect(_[\track]) })
		.flatten.as(Set).asArray.sort.collect(_.asString);
	paramItems = ["tempo"] ++ ~paramList.collect(_.asString);

	if(names.isEmpty) {
		"tempoGui: no cues loaded -- run SETUP / ~loadCueSheet first.".warn;
		nil
	} {
		updateInfo = {
			var idx = env.index;
			var sel = if(idx >= 0 and: { idx < model[\beats].size }) {
				"node %  @ %.2f beats, %.2f bpm".format(idx, model[\beats][idx], model[\bpms][idx])
			} { "(no node selected)" };
			info.string = " cue '%'    % nodes    %.2f beats long    %".format(
				currentName, model[\beats].size, cueLen, sel);
		};

		syncCurveMenu = {
			var seg = env.index.clip(0, (model[\curves].size - 1).max(0));
			(model[\curves].size > 0).if {
				var c = model[\curves][seg];
				if(c.isNumber) {                                  // numeric curvature
					curveNumBox.value_(c);
				} {                                                // named shape
					~tgCurveTypes.indexOf(c) !? { |w| curveMenu.value_(w) };
					curveNumBox.value_(0);
				};
			};
		};

		// model -> view (renormalize to 0..1 on both axes)
		refresh = {
			var xs = model[\beats].collect({ |b| (b / cueLen).clip(0, 1) });
			var ys = model[\bpms].collect({ |v| ((v - minBPM) / (maxBPM - minBPM)).clip(0, 1) });
			updating = true;
			env.value_([xs, ys]);
			env.curves_(model[\curves]);
			env.refresh;
			updating = false;
			updateInfo.value;
			graph !? (_.refresh);          // repaint the note backdrop for the loaded cue/track
		};

		// view -> model (after a drag), pin endpoints in x, store into ~tempoEnvs
		readView = {
			if(updating.not) {
				var v  = env.value;
				var xs = v[0].copy, ys = v[1];
				var n  = xs.size;
				xs[0] = 0; xs[n - 1] = 1;                        // pin left/right nodes horizontally
				model[\beats] = xs.collect({ |x| (x * cueLen).round(0.01) });
				model[\bpms]  = ys.collect({ |y| (minBPM + (y * (maxBPM - minBPM))).round(0.01) });
				model[\beats][0] = 0; model[\beats][n - 1] = cueLen;
				while({ model[\curves].size < (n - 1) }) { model[\curves] = model[\curves].add(\lin) };
				model[\curves] = model[\curves].keep(n - 1);
				storeEnv.(~tgModelToEnv.(model, yFloor.value));
				updating = true; env.value_([xs, ys]); updating = false;   // snap endpoints back
				updateInfo.value;
			};
		};

		loadCue = { |name|
			var cue = ~cues.detect({ |c| c[\name] == name });
			var existing;
			currentName = name;
			cueLen = ~cueBeatLength.(cue);
			existing = getEnv.value;
			model = if(existing.notNil) { ~tgEnvToModel.(existing) } { defaultModel.value };
			// stretch/clamp the envelope so it spans exactly the cue length
			if(model[\beats].last > 0) {
				var scale = cueLen / model[\beats].last;
				model[\beats] = model[\beats].collect({ |b| (b * scale).round(0.01) });
			};
			model[\beats][0] = 0;
			model[\beats][model[\beats].size - 1] = cueLen;
			// y-range: auto-fit for tempo (BPM), fixed per-param range otherwise
			if(curParam == \tempo) { # minBPM, maxBPM = ~tgAutoRange.(model[\bpms]) }
			{ # minBPM, maxBPM = ~paramRanges[curParam] };
			minBpmBox.value_(minBPM); maxBpmBox.value_(maxBPM);
			storeEnv.(~tgModelToEnv.(model, yFloor.value));
			refresh.value;
		};

		// ---- widgets ----
		cueMenu = PopUpMenu().items_(names).action_({ |m|
			readView.value;
			loadCue.value(names[m.value]);
			syncCurveMenu.value;
		});

		// track selector -- which track's param curve to edit ("*" = all tracks).
		// Disabled while editing \tempo (tempo is per-cue, one timeline, track-agnostic).
		trackMenu = PopUpMenu().items_(trackItems).action_({ |m|
			readView.value;
			curTrack = trackItems[m.value];
			loadCue.value(currentName);
			syncCurveMenu.value;
		});

		// param selector -- "tempo" (BPM) or one of the engine's ~paramList controls.
		paramMenu = PopUpMenu().items_(paramItems).action_({ |m|
			readView.value;
			curParam = if(m.value == 0) { \tempo } { ~paramList[m.value - 1] };
			trackMenu.enabled_(curParam != \tempo);
			yLabel.string_(if(curParam == \tempo) { "BPM" } { curParam.asString });
			loadCue.value(currentName);
			syncCurveMenu.value;
		});

		curveMenu = PopUpMenu().items_(~tgCurveTypes.collect(_.asString)).action_({ |m|
			var seg = env.index.clip(0, (model[\curves].size - 1).max(0));
			(model[\curves].size > 0).if {
				model[\curves][seg] = ~tgCurveTypes[m.value];
				curveNumBox.value_(0);                            // a named shape clears the numeric box
				storeEnv.(~tgModelToEnv.(model, yFloor.value));
				refresh.value;
			};
		});

		// Numeric curvature for the selected segment (Env accepts a number as a curve;
		// 0 == straight line, +/- bend the segment). Overrides the named shape.
		curveNumBox = NumberBox().decimals_(2).clipLo_(-20).clipHi_(20).align_(\right)
			.action_({ |b|
				var seg = env.index.clip(0, (model[\curves].size - 1).max(0));
				(model[\curves].size > 0).if {
					model[\curves][seg] = b.value;
					storeEnv.(~tgModelToEnv.(model, yFloor.value));
					refresh.value;
				};
			});

		addBtn = Button().states_([["+ node"]]).action_({
			var b = model[\beats], v = model[\bpms], c = model[\curves];
			var insAt = (env.index.max(0) + 1).clip(1, b.size - 1);   // always interior
			var ci = insAt - 1;
			model[\beats]  = b[..insAt-1] ++ [((b[insAt-1] + b[insAt]) / 2).round(0.01)] ++ b[insAt..];
			model[\bpms]   = v[..insAt-1] ++ [((v[insAt-1] + v[insAt]) / 2).round(0.01)] ++ v[insAt..];
			model[\curves] = c[..ci-1] ++ [c[ci]] ++ c[ci..];        // split segment, keep its curve
			storeEnv.(~tgModelToEnv.(model, yFloor.value));
			refresh.value;
		});

		remBtn = Button().states_([["- node"]]).action_({
			var n = model[\beats].size, idx = env.index;
			((n > 2) and: { idx > 0 } and: { idx < (n - 1) }).if {   // keep the two endpoints
				var ci = idx - 1;
				model[\beats]  = model[\beats][..idx-1] ++ model[\beats][idx+1..];
				model[\bpms]   = model[\bpms][..idx-1]  ++ model[\bpms][idx+1..];
				model[\curves] = model[\curves][..ci-1] ++ model[\curves][ci+1..];
				storeEnv.(~tgModelToEnv.(model, yFloor.value));
				refresh.value;
			};
		});

		audBtn  = Button().states_([["> audition"]]).action_({ ~play.(currentName) });
		saveBtn = Button().states_([["save all"]]).action_({
			~tempoEnvPath.notNil.if({ ~saveTempoEnvs.(~tempoEnvPath) }, { "tempoGui: ~tempoEnvPath not set.".warn });
		});

		maxBpmBox = NumberBox().decimals_(2).align_(\right)
			.action_({ |b| maxBPM = b.value.max(minBPM + 1); refresh.value });
		minBpmBox = NumberBox().decimals_(2).align_(\right)
			.action_({ |b| minBPM = b.value.clip(1, maxBPM - 1); refresh.value });

		info   = StaticText().string_("");
		yLabel = StaticText().string_("BPM").align_(\center);

		// Background piano-roll: the cue's MIDI notes as faint grey bars, painted on a
		// UserView UNDERNEATH a transparent EnvelopeView so the curve floats over them.
		// x = beat (note start..end over the cue length); y = pitch (high at top). For
		// the combined track "*" (or tempo, which is track-agnostic) every note is drawn;
		// otherwise only the selected track's notes.
		graph = UserView().background_(Color.grey(0.92));
		graph.drawFunc = { |uv|
			var w = uv.bounds.width, h = uv.bounds.height;
			var cue = ~cues.detect({ |c| c[\name] == currentName });
			var notes = (cue !? (_[\notes])) ? [];
			var minP, maxP, pr, laneH;
			// never show `visual board` tracks (F2 board control notes, not pitches)
			notes = notes.reject({ |n| (~trackRoleFor.(n[\track]) ? ())[\role] == \visual });
			if((curParam != \tempo) and: { curTrack != "*" }) {
				notes = notes.select({ |n| n[\track].asString == curTrack });
			};
			if(notes.notEmpty and: { cueLen > 0 }) {
				minP  = notes.collect(_[\midinote]).minItem;
				maxP  = notes.collect(_[\midinote]).maxItem;
				pr    = (maxP - minP).max(1);
				laneH = h / (pr + 1);
				Pen.fillColor = Color.grey(0.45, 0.5);
				notes.do({ |n|
					var x0 = (n[\startBeat] / cueLen) * w;
					var x1 = ((n[\startBeat] + n[\durBeats]) / cueLen) * w;
					var y  = (maxP - n[\midinote]) * laneH;
					Pen.fillRect(Rect(x0, y, (x1 - x0).max(1.5), (laneH * 0.8).clip(2, 14)));
				});
			};
		};

		// Transparent so the grey notes behind show through; explicit colors keep the
		// curve/nodes visible on the light backdrop.
		env = EnvelopeView(graph, Rect(0, 0, 400, 300))
			.keepHorizontalOrder_(true)
			.step_(0.0)
			.drawLines_(true).drawRects_(true)
			.background_(Color.clear)
			.colors_(Color.black, Color.grey(0.25))
			.action_({ readView.value; syncCurveMenu.value });

		// Keep the envelope filling the graph as the window resizes, and repaint notes.
		graph.onResize = {
			env.bounds_(Rect(0, 0, graph.bounds.width, graph.bounds.height));
			graph.refresh;
		};

		// Ctrl-click to ADD a node at the pointer; Shift-click to REMOVE the nearest one.
		// (Plain click/drag still moves nodes via EnvelopeView's native handling -- the
		// QtCollider event filter delivers these clicks to mouseDownAction regardless.)
		// Endpoints are never added past or removed -- they stay pinned to 0..cueLen.
		env.toolTip_("Ctrl-click: add node    Shift-click: remove node    drag: move");
		env.mouseDownAction = { |view, x, y, mods, button|
			var w = view.bounds.width, h = view.bounds.height;
			var beat = (x / w).clip(0, 1) * cueLen;                       // pixel -> beats
			var val  = minBPM + ((1 - (y / h)).clip(0, 1) * (maxBPM - minBPM));   // pixel -> y value
			var isShift = (mods & 0x02000000) != 0, isCtrl = (mods & 0x04000000) != 0;
			if((button == 0) and: { isCtrl || isShift }) {
				var b = model[\beats], v = model[\bpms], c = model[\curves];
				if(isCtrl) {                                              // add an interior node
					var i  = (b.detectIndex({ |bb| bb > beat }) ? (b.size - 1)).clip(1, b.size - 1);
					var ci = i - 1;
					model[\beats]  = b[..i-1] ++ [beat.clip(0.001, cueLen - 0.001).round(0.01)] ++ b[i..];
					model[\bpms]   = v[..i-1] ++ [val.round(0.01)] ++ v[i..];
					model[\curves] = c[..ci-1] ++ [c[ci]] ++ c[ci..];     // split segment, keep its curve
				} {                                                       // remove nearest interior node
					if(b.size > 2) {
						var best, bestD = 0.08;                           // within ~8% of the view (x & y)
						(1 .. b.size - 2).do({ |k|
							var d = ((b[k] - beat) / cueLen).hypot((v[k] - val) / (maxBPM - minBPM));
							if(d < bestD) { bestD = d; best = k };
						});
						best !? { |idx|
							var ci = idx - 1;
							model[\beats]  = b[..idx-1] ++ b[idx+1..];
							model[\bpms]   = v[..idx-1] ++ v[idx+1..];
							model[\curves] = c[..ci-1] ++ c[ci+1..];
						};
					};
				};
				storeEnv.(~tgModelToEnv.(model, yFloor.value));
				refresh.value;
				syncCurveMenu.value;
			};
		};

		win = Window("Curve Editor  (x = beats, y = tempo / param)", Rect(200, 200, 680, 470));
		win.layout_(VLayout(
			HLayout( StaticText().string_("cue:").maxWidth_(28), cueMenu, nil, audBtn, saveBtn ),
			HLayout( StaticText().string_("track:").maxWidth_(38), trackMenu,
				StaticText().string_("param:").maxWidth_(44), paramMenu, nil ),
			HLayout(
				graph,
				View().fixedWidth_(64).layout_(
					VLayout( yLabel, maxBpmBox, nil, minBpmBox )
				)
			),
			HLayout( addBtn, remBtn, StaticText().string_("curve:").maxWidth_(42), curveMenu,
				StaticText().string_("or #:").maxWidth_(34), curveNumBox.maxWidth_(70), nil ),
			info
		));
		win.front;

		trackMenu.enabled_(false);          // start on \tempo, which is track-agnostic
		loadCue.value(names[0]);
		cueMenu.value_(0);
		syncCurveMenu.value;
		// Size the envelope to fill the graph once the window has laid out (onResize
		// also handles this on later resizes), then paint the initial backdrop.
		{ env.bounds_(Rect(0, 0, graph.bounds.width, graph.bounds.height)); graph.refresh }.defer(0.1);
		win
	};
};

// convenience alias the Main file documents
~tempoGui = { ~openTempoEnvGui.value };

"tempo env GUI loaded.".postln;
)
