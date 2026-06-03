// ============================================================================
// cuePlayerEngine.scd  --  internals for the MIDI cue player.
//
// This is the "library". It is loaded once by midi_cue_player.scd via
//   this.executeFile("cuePlayerEngine.scd".resolveRelative)
// inside a booted server. A performer never edits this file; they drive it
// through the handful of one-liners exposed at the top of midi_cue_player.scd
// (~play / ~next / ~stop / ~cues).
//
// Design notes:
//   - MIDI is read with SimpleMIDIFile (wslib quark), left in default timeMode
//     \ticks, so note times never touch the file's tempo map. Beats are just
//     `ticks / division` (division = ticks per quarter note).
//   - Tempo is imposed by pre-integrating a BPM-over-beats Env: time(beat) is
//     the cumulative-trapezoid integral of 60/BPM(beat) over a dense grid, so it
//     honors whatever curve you draw. (\lin in BPM is NOT linear-in-period; \exp
//     is geometric-in-BPM. Use \exp for a smooth musical accel.)
//   - A "cue" is a beat WINDOW of a MIDI file (see ~readCueNotes). playCue jumps
//     to one, interrupting whatever is sounding; each cue runs in its own Group
//     on SystemClock in absolute seconds (tempo already baked in, no TempoClock).
//
// Requires: wslib quark  ->  Quarks.install("wslib");  (then recompile)
// ============================================================================
(
// ---------------------------------------------------------------------------
// Saw stand-in voice.
//   - ampEnv gives the note its computed duration and self-frees (doneAction 2).
//   - killEnv is a sustained gate at 1.0; \gate->0 fades it out fast so playCue
//     can interrupt the previous cue without a click.
//   - velocity -> amp is squared (roughly perceptual).
// ---------------------------------------------------------------------------
SynthDef(\sawCue, { |out = 0, freq = 440, amp = 0.2, dur = 1, atk = 0.005, rel = 0.06, gate = 1|
	var ampEnv = EnvGen.kr(
		Env([0, 1, 1, 0], [atk, (dur - atk - rel).max(0.001), rel], [\sin, \lin, \sin]),
		doneAction: 2
	);
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2); // \gate->0 = fast release
	var sig = Saw.ar(freq) * ampEnv * killEnv * amp;
	Out.ar(out, sig ! 2);
}).add;

// ---------------------------------------------------------------------------
// State + tempo-envelope storage. ~tempoEnvs maps a key -> Env of BPM over
// (window) BEATS. Lookup tries the cue's name, then its file, then the default.
// ---------------------------------------------------------------------------
~masterAmp       = 0.25;
~cues            = [];                       // [ (name:, file:, path:, startBeat:, endBeat:, notes:) ]
~cueIndex        = 0;                         // cursor: index of the cue ~next will play
~playing         = nil;                       // (routine:, group:, index:)
~tempoEnvs       = Dictionary.new;
~defaultTempoEnv = Env([120, 120], [1]);      // held at 120 BPM for the whole cue

~midiMap           = Dictionary.new;          // "type chan num" -> action token (\next, \stop, or cue name)
~midiLearning      = nil;                      // action awaiting a control during MIDI-learn, else nil
~midiLearnSavePath = nil;                      // if set, save the map right after the next learn
~midiMapPath       = nil;                      // default config path (SETUP sets this)
~tempoEnvPath      = nil;                      // default tempo-envelope config path (SETUP sets this)

~tempoEnvFor = { |cue|
	~tempoEnvs[cue[\name]] ?? { ~tempoEnvs[cue[\file]] ?? { ~defaultTempoEnv } };
};

// ---------------------------------------------------------------------------
// Read notes from one MIDI file, windowed to [startBeat, endBeat). Onset must
// fall inside the window: notes starting earlier are dropped, notes ending past
// endBeat are truncated, and beats are re-zeroed to start. (endBeat inf => whole
// file.)
// ---------------------------------------------------------------------------
~readCueNotes = { |path, startBeat = 0, endBeat = inf|
	var m   = SimpleMIDIFile.read(path);  // default timeMode == \ticks
	var div = m.division;                 // ticks per quarter note
	m.noteSustainEvents.collect({ |e|
		// e == [track, absTime, \noteOn, channel, note, velo, dur, upVelo]
		(startBeat: e[1] / div, durBeats: e[6] / div, midinote: e[4], vel: e[5])
	}).select({ |nt|
		(nt[\startBeat] >= startBeat) and: { nt[\startBeat] < endBeat }
	}).collect({ |nt|
		var s   = nt[\startBeat] - startBeat;                                // re-zero
		var end = (nt[\startBeat] + nt[\durBeats]).min(endBeat) - startBeat; // truncate
		(startBeat: s, durBeats: (end - s).max(0), midinote: nt[\midinote], vel: nt[\vel])
	});
};

~postLoaded = { |what|
	"loaded % cue(s)%:".format(~cues.size, what).postln;
	~cues.do({ |c, i| "  [%] %  (% notes)".format(i, c[\name], c[\notes].size).postln });
	~cues;
};

// ---------------------------------------------------------------------------
// Load whole files from a directory (lexicographic order, one cue each).
// ---------------------------------------------------------------------------
~loadCues = { |dir|
	var paths = ((dir +/+ "*.mid").pathMatch ++ (dir +/+ "*.midi").pathMatch).sort;
	~cues = paths.collect({ |p|
		(name: p.basename, file: p.basename, path: p,
			startBeat: 0, endBeat: inf, notes: ~readCueNotes.(p))
	});
	~cueIndex = 0;
	~postLoaded.("");
};

// ---------------------------------------------------------------------------
// Load windowed cues from a cue sheet (cues.txt). One cue per line:
//     filename start_beat end_beat [optional name...]
//   - Blank lines and lines beginning with '#' are ignored.
//   - filename is resolved relative to the cue sheet's directory; no spaces.
//   - If no name is given the cue is labelled "filename [start-end]".
// ---------------------------------------------------------------------------
~loadCueSheet = { |sheetPath|
	var path = sheetPath.standardizePath;
	var dir  = path.dirname;
	~cues = [];
	File.readAllString(path).split($\n).do({ |line|
		var t = line.stripWhiteSpace.replace("\t", " ");
		if(t.notEmpty and: { t[0] != $# }) {
			var tok = t.split($ ).reject({ |x| x.isEmpty });
			if(tok.size >= 3) {
				var fname = tok[0];
				var sB    = tok[1].asFloat;
				var eB    = tok[2].asFloat;
				var label = if(tok.size > 3) { tok[3..].join(" ") }
				            { "% [%-%]".format(fname, tok[1], tok[2]) };  // keep the text as written
				var p     = dir +/+ fname;
				~cues = ~cues.add(
					(name: label, file: fname, path: p,
						startBeat: sB, endBeat: eB, notes: ~readCueNotes.(p, sB, eB))
				);
			} {
				"loadCueSheet: skipping malformed line: %".format(line).warn;
			};
		};
	});
	~cueIndex = 0;
	~postLoaded.(" from " ++ path.basename);
};

// ---------------------------------------------------------------------------
// Tempo integration: build a beat -> seconds lookup table.
//   period(beat) = 60 / BPM(beat); time(beat) = cumulative trapezoid of period.
//   Beyond the envelope's duration we hold the final BPM (clamp the query).
// ---------------------------------------------------------------------------
~buildTimeMap = { |env, maxBeat, resolution = 0.01|
	var n       = (maxBeat / resolution).ceil.asInteger.max(1);
	var beats   = Array.fill(n + 1, { |i| i * resolution });
	var periods = beats.collect({ |b| 60 / env.at(b.min(env.duration)) }); // sec per beat
	var times   = Array.newClear(n + 1);
	times[0] = 0;
	(1..n).do({ |i|
		times[i] = times[i - 1] + ((periods[i - 1] + periods[i]) * 0.5 * resolution);
	});
	(beats: beats, times: times, resolution: resolution, maxBeat: beats.last);
};

~beatToTime = { |map, beat|
	var b   = beat.clip(0, map.maxBeat);
	var idx = (b / map.resolution).floor.asInteger;
	if(idx >= (map.times.size - 1)) {
		map.times.last
	} {
		var frac = (b - map.beats[idx]) / map.resolution;
		map.times[idx] + ((map.times[idx + 1] - map.times[idx]) * frac)
	};
};

// ---------------------------------------------------------------------------
// Stop / interrupt the currently playing cue (soft fade, then reap group).
// ---------------------------------------------------------------------------
~stopCue = {
	if(~playing.notNil) {
		var g = ~playing[\group];
		~playing[\routine].stop;
		g.set(\gate, 0);                              // fade sounding voices, they self-free
		SystemClock.sched(0.2, { g.free; nil });      // reap the (now empty) group
		~playing = nil;
	};
};

// ---------------------------------------------------------------------------
// Primitive: play the cue at the given index (interrupts current).
// ---------------------------------------------------------------------------
~playCue = { |index|
	var cue = ~cues[index];
	if(cue.isNil) {
		"playCue: no cue at index %".format(index).warn;
	} {
		var env, lastBeat, maxBeat, map, events, group, routine;

		~stopCue.value;

		env = ~tempoEnvFor.(cue);

		lastBeat = if(cue[\notes].isEmpty) { 0 } {
			cue[\notes].collect({ |nt| nt[\startBeat] + nt[\durBeats] }).maxItem
		};
		maxBeat = max(lastBeat, env.duration);
		map = ~buildTimeMap.(env, maxBeat);

		// Map each note's start/end beat through the integrated tempo curve.
		events = cue[\notes].collect({ |nt|
			var t0 = ~beatToTime.(map, nt[\startBeat]);
			var t1 = ~beatToTime.(map, nt[\startBeat] + nt[\durBeats]);
			(time: t0, dur: (t1 - t0).max(0.01), midinote: nt[\midinote], vel: nt[\vel])
		}).sort({ |a, b| a[\time] < b[\time] });

		group = Group.new(s);

		routine = Routine({
			var now = 0;
			events.do({ |ev|
				(ev[\time] - now).wait;   // SystemClock => waits in seconds
				now = ev[\time];
				Synth(\sawCue, [
					\freq, ev[\midinote].midicps,
					\amp,  ~masterAmp * (ev[\vel] / 127).squared,
					\dur,  ev[\dur]
				], group);
			});
			// Reached only on NATURAL completion -- a manual stop/interrupt halts
			// the routine first. Mark as stopped (so ~stop steps back next time) and
			// reap the now-finished group after a short tail.
			~playing = nil;
			SystemClock.sched(1.0, { group.free; nil });
		}).play(SystemClock);

		~playing  = (routine: routine, group: group, index: index);
		~cueIndex = (index + 1).min(~cues.size - 1);   // advance the cursor to the next cue
		"playing cue [%] %  (%.2f s)".format(index, cue[\name], map.times.last).postln;
	};
};

// ---------------------------------------------------------------------------
// Play the cue at the cursor; ~playCue advances the cursor afterward.
// ---------------------------------------------------------------------------
~playNext = {
	if(~cues.notEmpty) {
		~playCue.(~cueIndex);
	};
};

// ===========================================================================
// PERFORMER INTERFACE  (the names midi_cue_player.scd documents).
//   ~play.(id)  cue NAME ("1", "big finish", ...) or, failing that, a raw index
//   ~next.()    advance + play the next cue
//   ~stop.()    if sounding: fade out; if ALREADY stopped: step the cursor back
//               one cue (no playback) so the next ~next replays the earlier cue
// ===========================================================================
~play = { |id|
	var idx = ~cues.detectIndex({ |c| c[\name] == id.asString });
	~playCue.(idx ? id);
};

~next = ~playNext;

~stop = {
	if(~playing.notNil) {
		~stopCue.value;                          // sounding -> fade out
	} {
		if(~cues.notEmpty) {                      // already stopped -> just rewind the cursor
			~cueIndex = (~cueIndex - 1).max(0);
			"stepped back -- next cue is [%] %".format(~cueIndex, ~cues[~cueIndex][\name]).postln;
		};
	};
};

// ===========================================================================
// MIDI LEARN  --  bind physical controls (note-ons or CCs) to actions.
//   ~setupMIDI.value             once: open MIDI in, install responder, load map
//   ~learnMIDINext.([save])      then press a control to bind it to "next"
//   ~learnMIDIStop.([save])      ...to "stop"
//   ~learnMIDICue.(name,[save])  ...to play a specific cue
//   `save`: a file path (or `true` for ~midiMapPath) persists the whole map;
//           omit it to keep the binding for this session only.
//   ~learnMIDICancel.()  aborts an armed learn.
// A binding fires on value > 0 only (button press / note-on), so releases are
// ignored. Bindings are keyed by "type chan num", so the same pad on different
// channels are distinct controls.
// ===========================================================================

// Stored token <-> action: "next"/"stop" become symbols, anything else a cue name.
~actionFromToken = { |tok| switch(tok.asString, "next", { \next }, "stop", { \stop }, { tok.asString }) };

~fireAction = { |action|
	switch(action.asSymbol,
		\next, { ~next.value },
		\stop, { ~stop.value },
		{ ~play.(action) }                        // anything else: treat as a cue name
	);
};

// The responder: one call per incoming note-on / CC (already filtered to val > 0).
~onMidi = { |type, chan, num, val|
	var key = "% % %".format(type, chan, num);
	if(~midiLearning.notNil) {
		~midiMap[key] = ~midiLearning;
		"MIDI learned: %  ->  %".format(key, ~midiLearning).postln;
		~midiLearnSavePath !? { |p| ~saveMidiMap.(p) };
		~midiLearning = nil;
		~midiLearnSavePath = nil;
	} {
		~midiMap[key] !? { |action| ~fireAction.(action) };
	};
};

~setupMIDI = {
	MIDIClient.init(verbose:false);
	MIDIIn.connectAll(verbose:false);
	MIDIdef.noteOn(\cuePlayerNote, { |val, num, chan| (val > 0).if { ~onMidi.("note", chan, num, val) } });
	MIDIdef.cc(    \cuePlayerCC,   { |val, num, chan| (val > 0).if { ~onMidi.("cc",   chan, num, val) } });
	~midiMapPath !? { |p| ~loadMidiMap.(p) };
	"MIDI ready (% binding(s)). Use ~learnMIDINext / ~learnMIDIStop.".format(~midiMap.size).postln;
};

~learnMIDI = { |action, save|
	~midiLearning      = action;
	~midiLearnSavePath = if(save == true) { ~midiMapPath } { save };  // path string, or nil
	"MIDI learn armed for '%' -- press a control now%.".format(
		action, ~midiLearnSavePath.notNil.if({ " (saving to " ++ ~midiLearnSavePath ++ ")" }, { "" })
	).postln;
};
~learnMIDINext   = { |save| ~learnMIDI.(\next, save) };
~learnMIDIStop   = { |save| ~learnMIDI.(\stop, save) };
~learnMIDICue    = { |name, save| ~learnMIDI.(name.asString, save) };
~learnMIDICancel = { ~midiLearning = nil; ~midiLearnSavePath = nil; "MIDI learn cancelled.".postln };

~saveMidiMap = { |path|
	var p = path.standardizePath, f = File(p, "w");
	f.write("# cue player MIDI map -- one binding per line:  type chan num action\n");
	~midiMap.keysValuesDo({ |k, v| f.write("% %\n".format(k, v)) });  // v.asString: \next -> "next"
	f.close;
	"saved % MIDI binding(s) to %".format(~midiMap.size, p).postln;
};

~loadMidiMap = { |path|
	var p = path.standardizePath;
	if(File.exists(p)) {
		~midiMap = Dictionary.new;
		File.readAllString(p).split($\n).do({ |line|
			var t = line.stripWhiteSpace;
			if(t.notEmpty and: { t[0] != $# }) {
				var tok = t.split($ ).reject({ |x| x.isEmpty });
				if(tok.size >= 4) {
					~midiMap["% % %".format(tok[0], tok[1], tok[2])] = ~actionFromToken.(tok[3..].join(" "));
				};
			};
		});
		"loaded % MIDI binding(s) from %".format(~midiMap.size, p).postln;
	};
};

// ===========================================================================
// TEMPO-ENVELOPE PERSISTENCE  --  save/load ~tempoEnvs as plain text. One line
// per envelope:   <cue name> | <bpm levels> | <beat durations> | <curves>
// The name is everything before the first '|' (so spaces/brackets in cue names
// are fine). Curves are named shapes (lin/exp/sin/...) or numeric curvatures.
// ===========================================================================
~parseCurve = { |tok|
	// a numeric curvature, else a named shape symbol (\lin, \exp, \sin, ...)
	if(tok.notEmpty and: { tok.every({ |ch| "0123456789.eE+-".includes(ch) }) }) {
		tok.asFloat
	} {
		tok.asSymbol
	};
};

~saveTempoEnvs = { |path|
	var p = path.standardizePath, f = File(p, "w");
	f.write("# tempo envelopes:  name | bpm levels | beat durations | curves\n");
	~tempoEnvs.keysValuesDo({ |name, env|
		var curves = env.curves;
		if(curves.isArray.not) { curves = Array.fill(env.times.size.max(1), curves) };
		f.write("% | % | % | %\n".format(
			name,
			env.levels.join(" "),
			env.times.join(" "),
			curves.join(" ")
		));
	});
	f.close;
	"saved % tempo env(s) to %".format(~tempoEnvs.size, p).postln;
};

~loadTempoEnvs = { |path|
	var p = path.standardizePath, n = 0;
	if(File.exists(p)) {
		File.readAllString(p).split($\n).do({ |line|
			var t = line.stripWhiteSpace;
			if(t.notEmpty and: { t[0] != $# }) {
				var parts = t.split($|).collect(_.stripWhiteSpace);
				if(parts.size >= 3) {
					var name   = parts[0];
					var levels = parts[1].split($ ).reject(_.isEmpty).collect(_.asFloat);
					var times  = parts[2].split($ ).reject(_.isEmpty).collect(_.asFloat);
					var curves = if(parts.size >= 4) {
						parts[3].split($ ).reject(_.isEmpty).collect({ |c| ~parseCurve.(c) })
					} { \lin };
					~tempoEnvs[name] = Env(levels, times, curves);
					n = n + 1;
				};
			};
		});
		"loaded % tempo env(s) from %".format(n, p).postln;
	};
};

"cue player engine loaded.".postln;
)
