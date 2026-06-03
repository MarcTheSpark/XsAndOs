// TODO:
// 1) Enable Multiple parts, map synth to part
// 2) Visual voice (each midi pitch is mapped to square, player), newest addition is bold, if it's a chord, color it
// 3) Other sound properties

// ============================================================================
// midi_cue_player.scd  --  XsAndOs MIDI cue player.  PERFORMER ENTRY POINT.
//
// 1. Run the SETUP block (bottom of this file) ONCE at the start of a session.
//    It boots the server, loads the engine, and loads the cues.
// 2. After that, drive the piece with MIDI controls, which can be set
//    with these one-liners:
// ============================================================================

// --- Tempo curves: open the editor to draw BPM-over-beats for each cue ---
~tempoGui.();

// --- MIDI learn: bind a foot pedal / pad to an action, then play hands-free ---
~learnMIDINext.(true);        // arm, then press a control to bind it to "next"
~learnMIDIStop.(true);    // bind "stop" AND persist the mapping to the config file
~learnMIDICue.(1);        // bind a control straight to cue "1"
~learnMIDICancel.();      // abort an armed learn


// ============================================================================
// SETUP  --  evaluate this whole block once. (Everything else lives in
// cuePlayerEngine.scd; cues are defined in Cues/cues.txt.)
// ============================================================================
(
s.waitForBoot({
	this.executeFile("cuePlayerEngine.scd".resolveRelative);
	this.executeFile("tempoEnvGui.scd".resolveRelative);

	// Tempo envelopes, in BPM over each cue's (window) BEATS. These are only
	// starting points -- the tempo GUI (~tempoGui) and the saved tempos.txt below
	// override them. Curve types are honored literally; \exp = smooth accel.
	~tempoEnvs["1"] = Env([60, 100], [10], \exp);
	~tempoEnvs["2"] = Env([100, 160], [10], \exp);

	~loadCueSheet.("Cues/cues.txt".resolveRelative);

	~tempoEnvPath = "tempos.txt".resolveRelative;     // where drawn tempo curves persist
	~loadTempoEnvs.(~tempoEnvPath);                   // override the inline defaults if present

	~midiMapPath = "midi_map.txt".resolveRelative;    // where learned MIDI bindings persist
	~setupMIDI.value;                                 // open MIDI in + load any saved bindings

	"Ready. ~play/~next/~stop  |  ~tempoGui for tempo curves  |  ~learnMIDINext/Stop for MIDI.".postln;
});
)


// ============================================================================
// USAGE EXAMPLES
// ============================================================================

~play.(1);     // play cue "1"  (interrupts whatever is sounding)
~play.(2);     // play cue "2"
~next.();      // advance to the next cue
~stop.();      // stop; press again while already stopped to rewind the cursor one cue (no replay)

~cues.do({ |c, i| "[%] %".format(i, c[\name]).postln });   // list the loaded cues
