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

~tgModelToEnv = { |m|
	var beats = m[\beats];
	var durs  = (1 .. (beats.size - 1)).collect({ |i| (beats[i] - beats[i - 1]).max(0.001).round(0.01) });
	Env(m[\bpms].collect({ |v| v.max(1).round(0.01) }), durs, m[\curves]);
};

~openTempoEnvGui = {
	var win, env, cueMenu, curveMenu, addBtn, remBtn, audBtn, saveBtn, info;
	var minBpmBox, maxBpmBox;
	var minBPM = 40, maxBPM = 240, cueLen = 16;
	var currentName, model, names, updating = false;
	var refresh, readView, loadCue, updateInfo, syncCurveMenu;

	names = ~cues.collect({ |c| c[\name] });

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
				~tgCurveTypes.indexOf(model[\curves][seg]) !? { |w| curveMenu.value_(w) };
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
				~tempoEnvs[currentName] = ~tgModelToEnv.(model);
				updating = true; env.value_([xs, ys]); updating = false;   // snap endpoints back
				updateInfo.value;
			};
		};

		loadCue = { |name|
			var cue = ~cues.detect({ |c| c[\name] == name });
			currentName = name;
			cueLen = ~cueBeatLength.(cue);
			model = if(~tempoEnvs[name].notNil) { ~tgEnvToModel.(~tempoEnvs[name]) }
			        { (beats: [0, cueLen], bpms: [120, 120], curves: [\lin]) };
			// stretch/clamp the envelope so it spans exactly the cue length
			if(model[\beats].last > 0) {
				var scale = cueLen / model[\beats].last;
				model[\beats] = model[\beats].collect({ |b| (b * scale).round(0.01) });
			};
			model[\beats][0] = 0;
			model[\beats][model[\beats].size - 1] = cueLen;
			# minBPM, maxBPM = ~tgAutoRange.(model[\bpms]);   // auto-fit the BPM range
			minBpmBox.value_(minBPM); maxBpmBox.value_(maxBPM);
			~tempoEnvs[name] = ~tgModelToEnv.(model);
			refresh.value;
		};

		// ---- widgets ----
		cueMenu = PopUpMenu().items_(names).action_({ |m|
			readView.value;
			loadCue.value(names[m.value]);
			syncCurveMenu.value;
		});

		curveMenu = PopUpMenu().items_(~tgCurveTypes.collect(_.asString)).action_({ |m|
			var seg = env.index.clip(0, (model[\curves].size - 1).max(0));
			(model[\curves].size > 0).if {
				model[\curves][seg] = ~tgCurveTypes[m.value];
				~tempoEnvs[currentName] = ~tgModelToEnv.(model);
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
			~tempoEnvs[currentName] = ~tgModelToEnv.(model);
			refresh.value;
		});

		remBtn = Button().states_([["- node"]]).action_({
			var n = model[\beats].size, idx = env.index;
			((n > 2) and: { idx > 0 } and: { idx < (n - 1) }).if {   // keep the two endpoints
				var ci = idx - 1;
				model[\beats]  = model[\beats][..idx-1] ++ model[\beats][idx+1..];
				model[\bpms]   = model[\bpms][..idx-1]  ++ model[\bpms][idx+1..];
				model[\curves] = model[\curves][..ci-1] ++ model[\curves][ci+1..];
				~tempoEnvs[currentName] = ~tgModelToEnv.(model);
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

		info = StaticText().string_("");

		env = EnvelopeView()
			.keepHorizontalOrder_(true)
			.step_(0.0)
			.drawLines_(true).drawRects_(true)
			.action_({ readView.value; syncCurveMenu.value });

		win = Window("Tempo Envelope Editor  (x = beats, y = BPM)", Rect(200, 200, 680, 440));
		win.layout_(VLayout(
			HLayout( StaticText().string_("cue:").maxWidth_(28), cueMenu, nil, audBtn, saveBtn ),
			HLayout(
				env,
				View().fixedWidth_(64).layout_(
					VLayout( StaticText().string_("BPM").align_(\center), maxBpmBox, nil, minBpmBox )
				)
			),
			HLayout( addBtn, remBtn, StaticText().string_("curve:").maxWidth_(42), curveMenu, nil ),
			info
		));
		win.front;

		loadCue.value(names[0]);
		cueMenu.value_(0);
		syncCurveMenu.value;
		win
	};
};

// convenience alias the Main file documents
~tempoGui = { ~openTempoEnvGui.value };

"tempo env GUI loaded.".postln;
)
