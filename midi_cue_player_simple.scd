// ============================================================================
// Xs and Os  --  CONTROL SHEET
//
// To run a line: click anywhere in it, then press  Cmd+Return  (Shift+Return
// on some setups). The line flashes to show it ran.
// ============================================================================


// STEP 1 -- start everything (do this ONCE per session, then wait for "Ready.")
(
s.options.numOutputBusChannels_(4);
this.executeFile("lib/setup.scd".resolveRelative);
)

~toggleClick.();


// STEP 2 -- play the piece

~next.();      // play the next cue   (tap again to skip on to the following one)
~stop.();      // stop the current cue (the next ~next / ~play restarts it)
~play.(1);     // jump straight to a cue by number: 1, 2, 3, ...


// Practice slower (takes effect on the next cue)

~tempoMul = 0.5;   // 50% speed
~tempoMul = 1;      // back to full speed


// Set up a foot pedal / MIDI button (optional) -- run a line, then press the pedal

~learnMIDINext.(true);   // bind the pedal to "next"
~learnMIDIStop.(true);   // bind the pedal to "stop"
~learnMIDICancel.();     // cancel if you change your mind
