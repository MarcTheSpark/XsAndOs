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
//
// data/ is the performer's working config and is NOT tracked by git (so they can
// edit it freely). On a fresh clone it won't exist, so we seed it here from the
// tracked data_original/ -- copying only missing files, never clobbering edits.
// ============================================================================
(
var dataDir     = "../data".resolveRelative.standardizePath;
var dataOrigDir = "../data_original".resolveRelative.standardizePath;
var enginePath  = "cuePlayerEngine.scd".resolveRelative;
var curveGuiPath = "tempoEnvGui.scd".resolveRelative;
var boardGuiPath = "boardGui.scd".resolveRelative;
var synthTesterPath = "synthTesterGui.scd".resolveRelative;
var tracksPath  = dataDir +/+ "tracks.txt";
var cuesPath    = dataDir +/+ "cues.txt";
var temposPath  = dataDir +/+ "tempos.txt";
var otherCurvesPath = dataDir +/+ "otherCurves.txt";
var levelsPath  = dataDir +/+ "levels.txt";
var midiMapPath = dataDir +/+ "midi_map.txt";
var midiDir     = "../midi".resolveRelative;

// Seed data/ from data_original/ (fresh clone), without overwriting existing files.
if(File.exists(dataDir).not) { File.mkdir(dataDir) };
(dataOrigDir +/+ "*").pathMatch.do({ |src|
	var dst = dataDir +/+ src.basename;
	if(File.exists(dst).not) {
		File.use(dst, "w", { |f| f.write(File.readAllString(src)) });
		"setup: seeded data/% from data_original/".format(src.basename).postln;
	};
});

s.waitForBoot({
	this.executeFile(enginePath);                 // the engine (~play/~next/~stop, synths, ...)
	this.executeFile(curveGuiPath);               // ~curveGui curve editor
	this.executeFile(boardGuiPath);               // ~boardGui visualization board
	this.executeFile(synthTesterPath);            // ~synthGui voice tester

	~trackMapPath = tracksPath;
	~loadTrackMap.(tracksPath);                   // track -> synth/role map (load before cues)

	~midiDir = midiDir;                           // where the .mid source files live
	~loadCueSheet.(cuesPath);                     // filenames resolve against ~midiDir
	~loadCueSounds.value;                         // preload per-cue Cue<n>.wav files (sounds/), if any

	~tempoEnvPath   = temposPath;
	~otherCurvePath = otherCurvesPath;
	~loadCurves.(temposPath);                     // drawn tempo curves
	~loadCurves.(otherCurvesPath);                // drawn F3 (cue, track, param) curves

	~cueLevelPath = levelsPath;
	~loadCueLevels.(levelsPath);                  // per-cue volume levels

	~midiMapPath = midiMapPath;
	~setupMIDI.value;                             // open MIDI in + load saved bindings

	~startMonitor.value;                          // persistent \monitorMix (main 1/2 -> output 3 click monitor)

	~boardGui.(dimensions: 800@800, fullScreen: true);

	// Optionally start in PERFORMANCE MODE (click -> output 3, ~next lockout, banner).
	// The entry file sets ~startInPerformanceMode before executeFile'ing this file;
	// we flip it here -- AFTER the engine loaded (which inits ~performanceMode = false)
	// -- via the real toggle so the flag, click routing (~clickOut), and board banner
	// all move together. Guarded by .not so a re-run doesn't toggle it back off.
	if((~startInPerformanceMode == true) and: { ~performanceMode.not }) {
		~togglePerformanceMode.value;
	};

	"Ready.  ~play / ~next / ~stop.".postln;
});
)
