// ============================================================================
// tempoEnvGui.scd  --  a GUI to draw per-cue tempo curves (BPM over beats).
//
// Loaded once by midi_cue_player.scd (this.executeFile ...). Opens with
//   ~curveGui.value
// Built on the core EnvelopeView. The envelope ALWAYS spans the full cue: the
// x axis is the cue's length in beats with the first node pinned at the left and
// the last node pinned at the right. The y axis is BPM; its range is shown by the
// two boxes at the top-right / bottom-right of the graph (auto-fit on load,
// editable). Drag nodes to shape the curve, pick a curve type per segment,
// add/remove interior nodes, audition, and save (~saveCurves: tempos.txt +
// otherCurves.txt).
//
// Edits write straight into ~tempoEnvs[cueName], so ~play / ~next pick them up
// immediately. Numbers are kept to 2-decimal precision.
//
// Must stay ONE compilation unit (it is executeFile'd as a whole).
// ============================================================================
(
// Only curve shapes the EnvelopeView (QCurve) can render -- NOT \hold, which the
// audio Env accepts but QCurve does not (it throws in env.curves_, breaking the
// whole editor). \step is QCurve's hold-like shape.
~tgCurveTypes = [\lin, \exp, \sin, \wel, \sqr, \cub, \step];

// QCurve's accepted symbols; anything else (a stray \hold from an old tempos.txt,
// etc.) is shown as \lin so feeding it to the view never crashes refresh.
~tgViewCurveNames = Set[\step, \linear, \lin, \sine, \sin, \welch, \wel,
	\exponential, \exp, \squared, \sqr, \cubed, \cub];
~tgViewCurve = { |c| if(c.isNumber or: { ~tgViewCurveNames.includes(c) }) { c } { \lin } };

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
	var win, env, graph, cueMenu, trackMenu, paramMenu, curveMenu, curveNumBox, addBtn, remBtn, audBtn, saveBtn, dupBtn, revBtn, info;
	var revertCurves;
	var minBpmBox, maxBpmBox, yLabel, winStartBox, winEndBox;
	var viewStartFrac = 0, viewEndFrac = 1;     // editable view window as fractions of the cue (blank = 0 / 1)
	var viewLo = 0, viewHi = 16;                 // the same window in BEATS (set by rebuildView)
	var minBPM = 40, maxBPM = 240, cueLen = 16;
	var currentName, model, names, updating = false;
	var curParam = \tempo, curTrack = "*", trackKeys, trackLabels, paramItems;
	var refresh, readView, loadCue, updateInfo, syncCurveMenu;
	var storeEnv, getEnv, yFloor, defaultModel;
	var computeWindow, segCurveIndex, rebuildView, commit;

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

	// track menu lists only the AUDIO tracks declared in tracks.txt, shown by their
	// name (4th column, falling back to the index), plus "*" (= all tracks). trackKeys
	// holds the underlying value ("*" or the index string) used to key ~paramEnvs;
	// trackLabels is what the menu displays. param menu is tempo + the engine's ~paramList.
	trackKeys = ["*"] ++ ~trackRoles.keys.asArray.select({ |t| ~trackRoles[t][\role] == \audio })
		.sort.collect(_.asString);
	trackLabels = ["all"] ++ trackKeys[1..].collect({ |t| ~trackName.(t.asInteger) });
	paramItems = ["tempo"] ++ ~paramList.collect(_.asString);

	if(names.isEmpty) {
		"curveGui: no cues loaded -- run SETUP / ~loadCueSheet first.".warn;
		nil
	} {
		updateInfo = {
			var idx = env.index;
			var sel = if(idx >= 0 and: { idx < model[\beats].size }) {
				"node %  @ %.2f beats, %.2f bpm".format(idx, model[\beats][idx], model[\bpms][idx])
			} { "(no node selected)" };
			var winStr = if((viewLo > 0.0001) or: { viewHi < (cueLen - 0.0001) }) {
				"  [view %.2f-%.2f]".format(viewLo, viewHi) } { "" };
			info.string = " cue '%'    % nodes    %.2f beats%    %".format(
				currentName, model[\beats].size, cueLen, winStr, sel);
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

		// model -> view (renormalize to 0..1 on both axes). model is the WINDOWED view
		// (its beats span [viewLo, viewHi]); x maps over that window so the EnvelopeView
		// fills the graph with just the windowed portion of the curve.
		refresh = {
			var span = (viewHi - viewLo).max(0.001);
			var xs = model[\beats].collect({ |b| ((b - viewLo) / span).clip(0, 1) });
			var ys = model[\bpms].collect({ |v| ((v - minBPM) / (maxBPM - minBPM)).clip(0, 1) });
			updating = true;
			env.value_([xs, ys]);
			env.curves_(model[\curves].collect(~tgViewCurve));   // view-safe (no \hold, etc.)
			env.refresh;
			updating = false;
			updateInfo.value;
			graph !? (_.refresh);          // repaint the note backdrop for the loaded cue/track
		};

		// view -> model (after a drag): pin endpoints in x to the window edges, then
		// commit (splice the windowed view back into the full cue curve and store).
		readView = {
			if(updating.not) {
				var v  = env.value;
				var xs = v[0].copy, ys = v[1];
				var n  = xs.size;
				var span = (viewHi - viewLo);
				xs[0] = 0; xs[n - 1] = 1;                        // pin left/right nodes horizontally
				model[\beats] = xs.collect({ |x| (viewLo + (x * span)).round(0.01) });
				model[\bpms]  = ys.collect({ |y| (minBPM + (y * (maxBPM - minBPM))).round(0.01) });
				model[\beats][0] = viewLo; model[\beats][n - 1] = viewHi;
				while({ model[\curves].size < (n - 1) }) { model[\curves] = model[\curves].add(\lin) };
				model[\curves] = model[\curves].keep(n - 1);
				commit.value;
				updating = true; env.value_([xs, ys]); updating = false;   // snap endpoints back
				updateInfo.value;
			};
		};

		// The editable window in BEATS, from the fraction boxes. A degenerate/inverted
		// window (end <= start) falls back to the whole cue so the curve stays editable
		// (the note backdrop independently draws nothing for an invalid window).
		computeWindow = {
			var lo = viewStartFrac.clip(0, 1) * cueLen;
			var hi = viewEndFrac.clip(0, 1) * cueLen;
			if((hi - lo) < 0.001) { [0, cueLen] } { [lo, hi] };
		};

		// Index of the segment (curve) of full model `fm` that contains `beat`.
		segCurveIndex = { |fm, beat|
			var bs = fm[\beats];
			var i  = bs.detectIndex({ |bb| bb > beat });   // first node strictly past beat
			((if(i.isNil) { bs.size - 1 } { i }) - 1).clip(0, (fm[\curves].size - 1).max(0));
		};

		// Rebuild the windowed editable `model` from the FULL stored curve for the
		// current window, then refresh. The full curve is the source of truth; when the
		// window is the whole cue this is the full model verbatim, otherwise it's the
		// window's interior nodes bracketed by boundary nodes at viewLo/viewHi (their
		// values interpolated from the full curve). Read-only -- it never stores, so just
		// viewing a window or panning never alters the curve.
		rebuildView = {
			var fullEnv = getEnv.value;
			var fm = if(fullEnv.notNil) { ~tgEnvToModel.(fullEnv) } { defaultModel.value };
			# viewLo, viewHi = computeWindow.value;
			if((viewLo <= 0.0001) and: { viewHi >= (cueLen - 0.0001) }) {
				model = (beats: fm[\beats].copy, bpms: fm[\bpms].copy, curves: fm[\curves].asArray.copy);
			} {
				var fenv = ~tgModelToEnv.(fm, yFloor.value);
				var bs   = fm[\beats];
				var inIx = (0 .. bs.size - 1).select({ |i| (bs[i] > (viewLo + 0.0001)) and: { bs[i] < (viewHi - 0.0001) } });
				var vb   = [viewLo] ++ inIx.collect({ |i| bs[i] }) ++ [viewHi];
				var vv   = [fenv.at(viewLo)] ++ inIx.collect({ |i| fm[\bpms][i] }) ++ [fenv.at(viewHi)];
				var vc;
				if(inIx.isEmpty) {
					vc = [ fm[\curves][segCurveIndex.(fm, viewLo)] ];               // single segment viewLo->viewHi
				} {
					var a = inIx.first, b = inIx.last;
					// NB: SC's a..(b-1) descends (reverses!) when b == a, so guard it.
					var mid = if(b > a) { fm[\curves][a .. (b - 1)] } { [] };
					vc = [ fm[\curves][(a - 1).clip(0, fm[\curves].size - 1)] ]      // viewLo -> node a
					   ++ mid                                                        // interior segments
					   ++ [ fm[\curves][b.clip(0, fm[\curves].size - 1)] ];         // node b -> viewHi
				};
				model = (beats: vb, bpms: vv, curves: vc);
			};
			refresh.value;
		};

		// Splice the windowed `model` back into the full curve (nodes left of viewLo and
		// right of viewHi are taken verbatim from the stored full curve, which windowed
		// edits never touch) and store it. The inverse of rebuildView.
		commit = {
			var full;
			if((viewLo <= 0.0001) and: { viewHi >= (cueLen - 0.0001) }) {
				full = model;                                  // whole-cue view: model IS the full curve
			} {
				var fullEnv = getEnv.value;
				var fm = if(fullEnv.notNil) { ~tgEnvToModel.(fullEnv) } { defaultModel.value };
				var bs = fm[\beats], sz = fm[\beats].size, nc = fm[\curves].size;
				var leftIx  = (0 .. sz - 1).select({ |i| bs[i] < (viewLo - 0.0001) });
				var rightIx = (0 .. sz - 1).select({ |i| bs[i] > (viewHi + 0.0001) });
				var nl = leftIx.size, nr = rightIx.size;
				var leftInner  = if(nl >= 2) { fm[\curves][0 .. (nl - 2)] } { [] };
				var leftBound  = if(nl >= 1) { [ fm[\curves][(nl - 1).clip(0, nc - 1)] ] } { [] };
				var rightBound = if(nr >= 1) { [ fm[\curves][(sz - nr - 1).clip(0, nc - 1)] ] } { [] };
				var rightInner = if(nr >= 2) { fm[\curves][(sz - nr) .. (sz - 2)] } { [] };
				full = (
					beats:  leftIx.collect({ |i| bs[i] })        ++ model[\beats]  ++ rightIx.collect({ |i| bs[i] }),
					bpms:   leftIx.collect({ |i| fm[\bpms][i] }) ++ model[\bpms]   ++ rightIx.collect({ |i| fm[\bpms][i] }),
					curves: leftInner ++ leftBound ++ model[\curves] ++ rightBound ++ rightInner
				);
			};
			storeEnv.(~tgModelToEnv.(full, yFloor.value));
		};

		loadCue = { |name|
			var cue = ~cues.detect({ |c| c[\name] == name });
			var existing, fullM;
			currentName = name;
			cueLen = ~cueBeatLength.(cue);
			existing = getEnv.value;
			fullM = if(existing.notNil) { ~tgEnvToModel.(existing) } { defaultModel.value };
			// stretch/clamp the envelope so it spans exactly the cue length
			if(fullM[\beats].last > 0) {
				var scale = cueLen / fullM[\beats].last;
				fullM[\beats] = fullM[\beats].collect({ |b| (b * scale).round(0.01) });
			};
			fullM[\beats][0] = 0;
			fullM[\beats][fullM[\beats].size - 1] = cueLen;
			// y-range: auto-fit for tempo (BPM) over the WHOLE curve, fixed per-param range otherwise
			if(curParam == \tempo) { # minBPM, maxBPM = ~tgAutoRange.(fullM[\bpms]) }
			{ # minBPM, maxBPM = ~paramRanges[curParam] };
			minBpmBox.value_(minBPM); maxBpmBox.value_(maxBPM);
			storeEnv.(~tgModelToEnv.(fullM, yFloor.value));   // persist the (possibly stretched) full curve
			rebuildView.value;                                 // window it (from the fraction boxes) + refresh
		};

		// ---- widgets ----
		cueMenu = PopUpMenu().items_(names).action_({ |m|
			loadCue.value(names[m.value]);
			syncCurveMenu.value;
		});

		// track selector -- which track's param curve to edit ("*" = all tracks).
		// Disabled while editing \tempo (tempo is per-cue, one timeline, track-agnostic).
		trackMenu = PopUpMenu().items_(trackLabels).action_({ |m|
			curTrack = trackKeys[m.value];
			loadCue.value(currentName);
			syncCurveMenu.value;
		});

		// param selector -- "tempo" (BPM) or one of the engine's ~paramList controls.
		paramMenu = PopUpMenu().items_(paramItems).action_({ |m|
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
				commit.value;
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
					commit.value;
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
			commit.value;
			refresh.value;
		});

		remBtn = Button().states_([["- node"]]).action_({
			var n = model[\beats].size, idx = env.index;
			((n > 2) and: { idx > 0 } and: { idx < (n - 1) }).if {   // keep the two endpoints
				var ci = idx - 1;
				model[\beats]  = model[\beats][..idx-1] ++ model[\beats][idx+1..];
				model[\bpms]   = model[\bpms][..idx-1]  ++ model[\bpms][idx+1..];
				model[\curves] = model[\curves][..ci-1] ++ model[\curves][ci+1..];
				commit.value;
				refresh.value;
			};
		});

		audBtn  = Button().states_([["> audition"]]).action_({ ~play.(currentName) });
		saveBtn = Button().states_([["save all"]]).action_({ ~saveCurves.value });

		// Revert ONLY the current (cue, track, param) curve to what's on disk, leaving
		// every other curve's in-memory edits untouched. We reload the saved files into
		// scratch dictionaries, pull out just this curve's saved value (via getEnv), then
		// restore the live dictionaries and overwrite this one entry -- or drop it if the
		// file has no such curve (so it reverts to the default flat curve).
		revertCurves = {
			var keepT = ~tempoEnvs, keepP = ~paramEnvs, savedEnv;
			~tempoEnvs = Dictionary.new; ~paramEnvs = Dictionary.new;
			~tempoEnvPath   !? { |p| ~loadCurves.(p) };
			~otherCurvePath !? { |p| ~loadCurves.(p) };
			savedEnv = getEnv.value;                 // the saved value for the CURRENT curve
			~tempoEnvs = keepT; ~paramEnvs = keepP;  // restore the live (edited) dictionaries
			if(savedEnv.notNil) { storeEnv.(savedEnv) } {
				if(curParam == \tempo) { ~tempoEnvs.removeAt(currentName) }
				{ ~paramEnvs.removeAt(~paramKey.(currentName, curTrack, curParam)) };
			};
			loadCue.value(currentName);
			syncCurveMenu.value;
			"curveGui: reverted % curve (cue '%'%) to saved.".format(
				curParam, currentName, if(curParam == \tempo) { "" } { ", track " ++ curTrack }).postln;
		};
		revBtn  = Button().states_([["revert"]]).action_({ revertCurves.value });

		// Seed THIS cue from the PREVIOUS one in the list: copy the previous cue's
		// tempo curve and every one of its (track, param) curves into this cue, each
		// re-fit (x rescaled) to this cue's beat length, then reload the view. Useful
		// for a run of cues that share a tempo shape. A no-op on the first cue.
		dupBtn = Button().states_([["duplicate last"]]).action_({
			var idx   = cueMenu.value;
			var fitTo = { |e, len|                      // stretch an env to span `len` beats
				var total = e.times.sum;
				var sc    = if(total > 0) { len / total } { 1 };
				Env(e.levels.copy, e.times.collect({ |t| (t * sc).max(0.001).round(0.01) }), e.curves);
			};
			if(idx <= 0) {
				"curveGui: no previous cue to duplicate.".warn;
			} {
				var prevName = names[idx - 1];
				var curLen   = ~cueBeatLength.(~cues[idx]);
				var n        = 0;
				~tempoEnvs[prevName] !? { |e| ~tempoEnvs[currentName] = fitTo.(e, curLen); n = n + 1 };
				~paramEnvs.keys.asArray.do({ |k|
					var pp = k.split($\t);              // [cue, track, param]
					if(pp[0] == prevName) {
						~paramEnvs[~paramKey.(currentName, pp[1], pp[2])] = fitTo.(~paramEnvs[k], curLen);
						n = n + 1;
					};
				});
				if(n == 0) {
					"curveGui: previous cue '%' has no curves to duplicate.".format(prevName).warn;
				} {
					"duplicated % curve(s) from cue '%' -> '%'".format(n, prevName, currentName).postln;
					loadCue.value(currentName);        // reload the shown (track, param) view
					syncCurveMenu.value;
				};
			};
		});

		maxBpmBox = NumberBox().decimals_(2).align_(\right)
			.action_({ |b| maxBPM = b.value.max(minBPM + 1); refresh.value });
		minBpmBox = NumberBox().decimals_(2).align_(\right)
			.action_({ |b| minBPM = b.value.clip(1, maxBPM - 1); refresh.value });

		// View window: fractions of the cue (0..1) to zoom the editor INTO -- both the
		// editable curve and the note backdrop. Blank start = 0, blank end = 1; an
		// inverted window (end <= start) draws no notes and leaves the curve at full cue.
		// rebuildView re-windows the curve (read-only -- live edits already persist).
		winStartBox = TextField().align_(\right)
			.action_({ |t|
				viewStartFrac = if(t.string.stripWhiteSpace.isEmpty) { 0 } { t.string.asFloat.clip(0, 1) };
				rebuildView.value;
			});
		winEndBox = TextField().align_(\right)
			.action_({ |t|
				viewEndFrac = if(t.string.stripWhiteSpace.isEmpty) { 1 } { t.string.asFloat.clip(0, 1) };
				rebuildView.value;
			});

		info   = StaticText().string_("");
		yLabel = StaticText().string_("BPM").align_(\center);

		// Background piano-roll: the cue's MIDI notes as faint grey bars, painted on a
		// UserView UNDERNEATH a transparent EnvelopeView so the curve floats over them.
		// x = beat (note start..end over the cue length); y = pitch (high at top). For
		// the combined track "*" (or tempo, which is track-agnostic) every note is drawn;
		// otherwise only the selected track's notes. The view boxes window the backdrop to
		// a fraction of the cue (e.g. 0.2..0.8 zooms to 20-80%, in lockstep with the curve
		// above it); an empty box means the cue start (0) / end (1), and a nonsensical
		// window (end <= start) just draws no notes.
		graph = UserView().background_(Color.grey(0.92));
		graph.drawFunc = { |uv|
			var w = uv.bounds.width, h = uv.bounds.height;
			var cue = ~cues.detect({ |c| c[\name] == currentName });
			var notes = (cue !? (_[\notes])) ? [];
			var minP, maxP, pr, laneH;
			var vs = viewStartFrac.clip(0, 1), ve = viewEndFrac.clip(0, 1);
			var wStart = vs * cueLen, wEnd = ve * cueLen, wLen = (wEnd - wStart);
			// never show `visual board` tracks (F2 board control notes, not pitches)
			notes = notes.reject({ |n| (~trackRoleFor.(n[\track]) ? ())[\role] == \visual });
			if((curParam != \tempo) and: { curTrack != "*" }) {
				notes = notes.select({ |n| n[\track].asString == curTrack });
			};
			if(notes.notEmpty and: { cueLen > 0 } and: { wLen > 0 }) {     // wLen <= 0 (end <= start) => draw nothing
				minP  = notes.collect(_[\midinote]).minItem;
				maxP  = notes.collect(_[\midinote]).maxItem;
				pr    = (maxP - minP).max(1);
				laneH = h / (pr + 1);
				Pen.fillColor = Color.grey(0.45, 0.5);
				notes.do({ |n|
					var x0 = ((n[\startBeat] - wStart) / wLen) * w;
					var x1 = ((n[\startBeat] + n[\durBeats] - wStart) / wLen) * w;
					var y  = (maxP - n[\midinote]) * laneH;
					if((x1 > 0) and: { x0 < w }) {                          // overlaps the visible window
						var xa = x0.max(0), xb = x1.min(w);
						Pen.fillRect(Rect(xa, y, (xb - xa).max(1.5), (laneH * 0.8).clip(2, 14)));
					};
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
		// Endpoints are never added past or removed -- they stay pinned to the view edges.
		// Pixels map through the current view window [viewLo, viewHi].
		env.toolTip_("Ctrl-click: add node    Shift-click: remove node    drag: move");
		env.mouseDownAction = { |view, x, y, mods, button|
			var w = view.bounds.width, h = view.bounds.height;
			var span = (viewHi - viewLo).max(0.001);
			var beat = viewLo + ((x / w).clip(0, 1) * span);              // pixel -> beats (within the window)
			var val  = minBPM + ((1 - (y / h)).clip(0, 1) * (maxBPM - minBPM));   // pixel -> y value
			var isShift = (mods & 0x02000000) != 0, isCtrl = (mods & 0x04000000) != 0;
			if((button == 0) and: { isCtrl || isShift }) {
				var b = model[\beats], v = model[\bpms], c = model[\curves];
				if(isCtrl) {                                              // add an interior node
					var i  = (b.detectIndex({ |bb| bb > beat }) ? (b.size - 1)).clip(1, b.size - 1);
					var ci = i - 1;
					model[\beats]  = b[..i-1] ++ [beat.clip(viewLo + 0.001, viewHi - 0.001).round(0.01)] ++ b[i..];
					model[\bpms]   = v[..i-1] ++ [val.round(0.01)] ++ v[i..];
					model[\curves] = c[..ci-1] ++ [c[ci]] ++ c[ci..];     // split segment, keep its curve
				} {                                                       // remove nearest interior node
					if(b.size > 2) {
						var best, bestD = 0.08;                           // within ~8% of the view (x & y)
						(1 .. b.size - 2).do({ |k|
							var d = ((b[k] - beat) / span).hypot((v[k] - val) / (maxBPM - minBPM));
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
				commit.value;
				refresh.value;
				syncCurveMenu.value;
			};
		};

		win = Window("Curve Editor  (x = beats, y = tempo / param)", Rect(200, 200, 680, 470));
		win.layout_(VLayout(
			HLayout( StaticText().string_("cue:").maxWidth_(28), cueMenu, dupBtn, nil, audBtn, revBtn, saveBtn ),
			HLayout( StaticText().string_("track:").maxWidth_(38), trackMenu,
				StaticText().string_("param:").maxWidth_(44), paramMenu, nil ),
			HLayout( StaticText().string_("view (0-1):").maxWidth_(72),
				winStartBox.maxWidth_(60), StaticText().string_("to").maxWidth_(16),
				winEndBox.maxWidth_(60), nil ),
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
		// Autosave on close: persist all curves (tempos.txt + otherCurves.txt) so closing
		// the editor never silently loses edits. Use "revert" beforehand to discard them.
		win.onClose = { ~saveCurves.value };
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
~curveGui = { ~openTempoEnvGui.value };

"tempo env GUI loaded.".postln;
)
