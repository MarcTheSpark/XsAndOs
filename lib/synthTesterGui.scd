// ============================================================================
// synthTesterGui.scd  --  audition the cue voices listed in tracks.txt.
//
// A single compilation unit, executeFile'd by lib/setup.scd (like tempoEnvGui /
// boardGui). Defines ~openSynthTester / ~synthGui. Unlike the standalone
// lib/synthOptions.scd timbre lab, this does NOT boot a server or define any
// synths -- it plays the SAME SynthDefs the engine already added (\sawCue,
// \velvetSawCue, \lorenzCue, ...) and lists exactly the ones a track routes to
// (the `audio` targets in ~trackRoles), so you hear what the cue player plays.
//
// The cue synths share one arg contract but not every control (basic voices have
// atk/cutoff; velvet/lorenz have sharp/chaos/sat), so the editor queries each
// SynthDef's real controls (via SynthDescLib) and greys out sliders the selected
// voice doesn't declare -- only the live controls are set.
//
// Note-life is the SynthDef's job: each voice bakes its length into a `dur`-timed
// ampEnv that self-frees, so "play note" triggers a note of the current `dur` and
// you hear its full envelope. "hold" plays a long note and "release" drops gate
// (the fast killEnv cue-stop fade), to audition the sustained body.
// ============================================================================
(
// All controls the tester can drive, with an audition range. A slider is shown
// for each; on synth-change the ones the selected voice doesn't declare are
// disabled. Keys are the SynthDef control names 1:1 (freq/amp/dur always exist).
~synthTestSpecs = [
	[\freq,   ControlSpec(40, 4000, \exp, 0, 440, " Hz")],
	[\amp,    ControlSpec(0, 1, \amp, 0, 0.2)],
	[\dur,    ControlSpec(0.05, 12, \exp, 0, 1, " s")],
	[\atk,    ControlSpec(0.001, 1, \exp, 0, 0.005, " s")],
	[\rel,    ControlSpec(0.01, 6, \exp, 0, 0.3, " s")],
	[\cutoff, ControlSpec(20, 20000, \exp, 0, 20000, " Hz")],
	[\sharp,  ControlSpec(0, 1, \lin, 0, 0.5)],
	[\chaos,  ControlSpec(0, 1, \lin, 0, 0.0)],
	[\sat,    ControlSpec(0, 1, \lin, 0, 0.3)],
	[\pan,    ControlSpec(-1, 1, \lin, 0, 0.0)]
];
~synthTestKeys  = ~synthTestSpecs.collect(_[0]);
~synthTestState = ();   // key -> current value (seeded from spec defaults)
~synthTestSpecs.do({ |s| ~synthTestState[s[0]] = s[1].default });

~synthTestCurrent = nil;   // selected SynthDef name (a Symbol)
~synthTestHeld    = nil;   // the sustaining "hold" Synth, else nil
~synthTestGroup   = nil;   // group the auditions play in (panic frees it)

// Distinct `audio` targets from tracks.txt (the voices actually in play). Falls
// back to the known cue library if no track map is loaded yet.
~synthTestVoices = {
	var fromTracks = ~trackRoles.values
		.select({ |r| r[\role] == \audio })
		.collect({ |r| r[\target] }).as(Set).asArray;
	if(fromTracks.isEmpty) {
		[\sawCue, \pulseCue, \tremCue, \triCue, \velvetSawCue, \lorenzCue]
	} {
		fromTracks
	}.sort({ |a, b| a.asString < b.asString });
};

// Control names the given SynthDef declares (Set of Symbols), for greying out.
~synthTestControlsOf = { |name|
	var desc = SynthDescLib.global.at(name);
	if(desc.notNil) { desc.controlNames.as(Set) } { Set[] };
};

// Args for a fresh note: every spec key the selected voice actually declares.
~synthTestArgs = {
	var have = ~synthTestControlsOf.(~synthTestCurrent);
	~synthTestKeys.select({ |k| have.includes(k) })
		.collect({ |k| [k, ~synthTestState[k]] }).flatten;
};

~synthTestEnsureGroup = {
	if(~synthTestGroup.isNil or: { ~synthTestGroup.isPlaying.not }) {
		~synthTestGroup = Group.new(s);
	};
};

~synthTestRelease = {
	~synthTestHeld !? { |sy| sy.set(\gate, 0) };
	~synthTestHeld = nil;
};

// Play a single note of the current `dur` -- its ampEnv frees it (doneAction 2).
~synthTestPlayNote = {
	~synthTestCurrent !? {
		~synthTestEnsureGroup.value;
		Synth(~synthTestCurrent, ~synthTestArgs.value ++ [\gate, 1], ~synthTestGroup);
	};
};

// Sustained audition: a long note held open; ~synthTestRelease drops the gate.
~synthTestHold = {
	~synthTestCurrent !? {
		var have = ~synthTestControlsOf.(~synthTestCurrent);
		~synthTestRelease.value;
		~synthTestEnsureGroup.value;
		~synthTestHeld = Synth(~synthTestCurrent,
			~synthTestKeys.select({ |k| have.includes(k) and: { k != \dur } })
				.collect({ |k| [k, ~synthTestState[k]] }).flatten
			++ [\dur, 600, \gate, 1],   // long dur so the ampEnv won't free it mid-audition
			~synthTestGroup);
	};
};

~synthTestPanic = {
	~synthTestRelease.value;
	~synthTestGroup !? { |g| g.free };
	~synthTestGroup = nil;
};

// ----------------------------------------------------------------------- GUI
~openSynthTester = {
	var voices = ~synthTestVoices.value;
	var win, sliders = (), info, y;
	~synthTestCurrent = voices.includes(~synthTestCurrent).if({ ~synthTestCurrent }, { voices[0] });

	win = Window("Synth Tester  (cue voices)", Rect(220, 220, 440, 470));

	StaticText(win, Rect(12, 12, 52, 24)).string_(" voice:");
	PopUpMenu(win, Rect(66, 12, 250, 24))
		.items_(voices.collect(_.asString))
		.value_(voices.indexOf(~synthTestCurrent))
		.action_({ |m|
			~synthTestCurrent = voices[m.value];
			~synthTestRelease.value;
			~synthTestSyncSliders.value;
		});

	info = StaticText(win, Rect(324, 12, 104, 24)).string_("").align_(\right);

	y = 46;
	~synthTestSpecs.do({ |spc|
		var key = spc[0];
		sliders[key] = EZSlider(win, Rect(12, y, 416, 26), key.asString, spc[1],
			{ |ez|
				~synthTestState[key] = ez.value;
				// live-update a held audition (only if this voice has the control)
				~synthTestHeld !? { |sy|
					if(~synthTestControlsOf.(~synthTestCurrent).includes(key)) { sy.set(key, ez.value) };
				};
			},
			~synthTestState[key], labelWidth: 56, numberWidth: 76);
		y = y + 32;
	});

	// Enable only the sliders the selected voice declares; grey the rest.
	~synthTestSyncSliders = {
		var have = ~synthTestControlsOf.(~synthTestCurrent);
		~synthTestKeys.do({ |k| sliders[k].enabled_(have.includes(k)) });
		info.string_("% ctl".format(have.select({ |k| ~synthTestKeys.includes(k) }).size));
	};
	~synthTestSyncSliders.value;

	y = y + 10;
	Button(win, Rect(12, y, 130, 36)).states_([["play note"]])
		.action_({ ~synthTestPlayNote.value });
	Button(win, Rect(150, y, 160, 36))
		.states_([["hold",    Color.black, Color.new(0.6, 0.85, 0.6)],
		          ["release", Color.white, Color.new(0.8, 0.3, 0.3)]])
		.action_({ |b| if(b.value == 1) { ~synthTestHold.value } { ~synthTestRelease.value } });
	Button(win, Rect(318, y, 110, 36)).states_([["panic"]])
		.action_({ ~synthTestPanic.value });

	win.onClose = { ~synthTestPanic.value; ~synthTestSyncSliders = nil };
	win.front;
	win;
};

~synthGui = ~openSynthTester;   // short alias, parallel to ~curveGui / ~boardGui
"synthTesterGui loaded -- ~synthGui.() to audition the track voices.".postln;
)
