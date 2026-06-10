// ============================================================================
// setup.scd  --  one-shot session setup for Xs and Os.
//
// executeFile'd by the player files (midi_cue_player.scd / _simple.scd) as a
// single line. Boots the server, loads the engine + GUIs, the track map, the
// cue sheet, the saved tempo/param curves, and MIDI -- then opens the board.
//
// Paths are resolved RELATIVE TO THIS FILE (lib/), and resolved up-front
// (synchronously) so they still work inside the async waitForBoot callback.
// Must stay ONE compilation unit (it is executeFile'd as a whole).
// ============================================================================
(
var enginePath  = "cuePlayerEngine.scd".resolveRelative;
var tempoGuiPath = "tempoEnvGui.scd".resolveRelative;
var boardGuiPath = "boardGui.scd".resolveRelative;
var tracksPath  = "../data/tracks.txt".resolveRelative;
var cuesPath    = "../data/cues.txt".resolveRelative;
var temposPath  = "../data/tempos.txt".resolveRelative;
var midiMapPath = "../data/midi_map.txt".resolveRelative;
var midiDir     = "../midi".resolveRelative;

s.waitForBoot({
	this.executeFile(enginePath);                 // the engine (~play/~next/~stop, synths, ...)
	this.executeFile(tempoGuiPath);               // ~tempoGui curve editor
	this.executeFile(boardGuiPath);               // ~boardGui visualization board

	~trackMapPath = tracksPath;
	~loadTrackMap.(tracksPath);                   // track -> synth/role map (load before cues)

	~midiDir = midiDir;                           // where the .mid source files live
	~loadCueSheet.(cuesPath);                     // filenames resolve against ~midiDir

	~tempoEnvPath = temposPath;
	~loadTempoEnvs.(temposPath);                  // drawn tempo/param curves

	~midiMapPath = midiMapPath;
	~setupMIDI.value;                             // open MIDI in + load saved bindings

	~boardGui.(dimensions: 800@800, fullScreen: true);
	"Ready.  ~play / ~next / ~stop.".postln;
});
)
