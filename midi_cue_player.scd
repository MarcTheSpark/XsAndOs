// ============================================================================
// midi_cue_player.scd  --  XsAndOs MIDI cue player.  PERFORMER ENTRY POINT.
//
// 1. Run the SETUP block (bottom of this file) ONCE at the start of a session.
//    It boots the server, loads the engine, and loads the cues.
// 2. After that, drive the piece with MIDI controls, which can be set
//    with these one-liners:
// ============================================================================

// --- Curve editor: draw tempo (BPM) or per-(track, param) curves for each cue ---
~tempoGui.();

// --- Visualization: open the Xs-and-Os board (driven by any `visual board` track) ---
~boardGui.();

// --- MIDI learn: bind a foot pedal / pad to an action, then play hands-free ---
~learnMIDINext.(true);        // arm, then press a control to bind it to "next"
~learnMIDIStop.(true);    // bind "stop" AND persist the mapping to the config file
~learnMIDICue.(1);        // bind a control straight to cue "1"
~learnMIDICancel.();      // abort an armed learn

s.boot

// ============================================================================
// SETUP  --  evaluate this whole block once. (Everything else lives in
// lib/cuePlayerEngine.scd; cues are defined in data/cues.txt.)
// ============================================================================
(
s.waitForBoot({
	this.executeFile("lib/cuePlayerEngine.scd".resolveRelative);
	this.executeFile("lib/tempoEnvGui.scd".resolveRelative);
	this.executeFile("lib/boardGui.scd".resolveRelative);

	// Tempo envelopes, in BPM over each cue's (window) BEATS. These are only
	// starting points -- the tempo GUI (~tempoGui) and the saved tempos.txt below
	// override them. Curve types are honored literally; \exp = smooth accel.
	~tempoEnvs["1"] = Env([60, 100], [10

	], \exp);
	~tempoEnvs["2"] = Env([100, 160], [10], \exp);

	~trackMapPath = "data/tracks.txt".resolveRelative;     // track -> synth/role map (global to the piece)
	~loadTrackMap.(~trackMapPath);                    // load before the cue sheet so routing is ready

	~midiDir = "midi".resolveRelative;                // where the .mid source files live
	~loadCueSheet.("data/cues.txt".resolveRelative);  // filenames resolve against ~midiDir

	~tempoEnvPath = "data/tempos.txt".resolveRelative;     // where drawn tempo curves persist
	~loadTempoEnvs.(~tempoEnvPath);                   // override the inline defaults if present

	~midiMapPath = "data/midi_map.txt".resolveRelative;    // where learned MIDI bindings persist
	~setupMIDI.value;                                 // open MIDI in + load any saved bindings

	"Ready. ~play/~next/~stop  |  ~tempoGui for tempo curves  |  ~learnMIDINext/Stop for MIDI.".postln;
});
)


// ============================================================================
// USAGE EXAMPLES
// ============================================================================

~play.("1");   // play cue named "1"  (interrupts whatever is sounding)
~play.(1);     // play the 1st cue by number (1-based, matching the score)
~play.(2);     // play the 2nd cue
~next.();      // advance to the next cue
~stop.();      // stop; press again while already stopped to rewind the cursor one cue (no replay)

~cues.do({ |c, i| "[%] %".format(i + 1, c[\name]).postln });   // list the loaded cues (1-based)
