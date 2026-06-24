// ============================================================================
// midi_cue_player.scd  --  XsAndOs MIDI cue player.  ENTRY POINT (full).
//
// 1. Run the SETUP line below ONCE at the start of a session. It boots the
//    server, loads the engine + GUIs, and loads the cues (see lib/setup.scd).
// 2. After that, drive the piece with the one-liners further down.
//
// (For a stripped-down sheet to hand to a performer, see
//  midi_cue_player_simple.scd.)
// ============================================================================

// --- SETUP: evaluate this one line once. Wait for "Ready." -------------------
this.executeFile("lib/setup.scd".resolveRelative);

// --- Play ------------------------------------------------------------------
~play.("1");   // play cue named "1"  (interrupts whatever is sounding)
~play.(1);     // play the 1st cue by number (1-based, matching the score)
~next.();      // advance to / play the next cue (tap again mid-cue to skip on)
~stop.();      // stop; press again while stopped to rewind the cursor one cue
~goToCue.(7);  // move the cursor to cue 7 WITHOUT playing (next ~next/~play starts there)

~cues.do({ |c, i| "[%] %".format(i + 1, c[\name]).postln });   // list cues (1-based)

// --- Per-cue volume: a fixed amplitude multiplier (1 = as written). Persists to levels.txt. ---
~setCueVolume.(7, 0.5);   // cue 7 at half volume

// --- Practice tempo: scale ALL tempos (1 = as written, 0.5 = half). Next ~play. ---
~tempoMul = 0.75;
~tempoMul = 1;

// --- Click track: toggle the metronome between main outputs 1/2 and output 3 (monitor) ---
~toggleClick.();

// --- Curve editor: draw tempo (BPM) or per-(track, param) curves for each cue ---
~curveGui.();

// --- Synth tester: audition the cue voices listed in tracks.txt (play/hold a note) ---
~synthGui.();

// --- Visualization: open the Xs-and-Os board (driven by any `visual board` track) ---
~boardGui.();                          // default 800x800 board, windowed
~boardGui.(700@700);                   // different fixed board size (centered)
~boardGui.(dimensions: 800@800, fullScreen: true);   // fullscreen ('f' / Esc to toggle)
~toggleCueNum.();                      // show/hide the current cue number in the board corner ('q' on the board)

// --- MIDI learn: bind a foot pedal / pad to an action, then play hands-free ---
~learnMIDINext.(true);    // arm, then press a control to bind it to "next"
~learnMIDIStop.(true);    // bind "stop" AND persist the mapping to the config file
~learnMIDICue.(1);        // bind a control straight to cue "1"
~learnMIDICancel.();      // abort an armed learn

// --- Inspection ------------------------------------------------------------
~fileTracks.();           // tracks in the cursor cue's whole MIDI file
~cueTracks.();            // tracks in the cursor cue's windowed notes

