// ============================================================================
// cuePlayerEngine.scd  --  internals for the MIDI cue player.
//
// This is the "library". It is loaded once by midi_cue_player.scd via
//   this.executeFile("lib/cuePlayerEngine.scd".resolveRelative)
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
//   - ampEnv holds for the note's full `dur`, THEN releases over `rel` (total
//     life dur + rel) and self-frees (doneAction 2). The release tail therefore
//     rings PAST `dur` into the next note (natural; can thicken dense passages).
//   - killEnv is a sustained gate at 1.0; \gate->0 fades it out fast so playCue
//     can interrupt the previous cue without a click.
//   - velocity -> amp is squared (roughly perceptual).
// ---------------------------------------------------------------------------
// Shared arg contract: out/freq/amp/dur/atk/rel/gate PLUS the F3 param controls
// cutoff (LPF), pan, and ampScale. Param curves (~paramEnvs) drive control buses that
// note synths .map their matching controls to, so a synth simply declares whichever it
// wants driven. `amp` is the velocity-derived level; `ampScale` (default 1) is a SEPARATE
// multiplier the amp curve drives, so an amp curve SCALES velocity rather than replacing
// it. Keep this contract in sync with ~paramList in the state block below.
SynthDef(\sawCue, { |out = 0, freq = 440, amp = 0.2, dur = 1, atk = 0.005, rel = 0.06, gate = 1, cutoff = 20000, pan = 0, ampScale = 1|
	var ampEnv = EnvGen.kr(
		Env([0, 1, 1, 0], [atk, (dur - atk).max(0.001), rel], [\sin, \lin, \sin]),
		doneAction: 2
	);
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2); // \gate->0 = fast release
	var sig = LPF.ar(Saw.ar(freq), cutoff.clip(20, 20000)) * ampEnv * killEnv * amp * ampScale;
	Out.ar(out, Pan2.ar(sig, pan.clip(-1, 1)));
}).add;

// Sibling voices: same arg contract as \sawCue, so any track can be routed to any of
// them via tracks.txt. Distinct waveforms only -- stand-ins, not realistic instruments.
SynthDef(\pulseCue, { |out = 0, freq = 440, amp = 0.2, dur = 1, atk = 0.005, rel = 0.06, gate = 1, cutoff = 20000, pan = 0, ampScale = 1|
	var ampEnv  = EnvGen.kr(Env([0, 1, 1, 0], [atk, (dur - atk).max(0.001), rel], [\sin, \lin, \sin]), doneAction: 2);
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2);
	var sig = LPF.ar(LPF.ar(Pulse.ar(freq, 0.35), freq * 6), cutoff.clip(20, 20000)) * ampEnv * killEnv * amp * ampScale;
	Out.ar(out, Pan2.ar(sig, pan.clip(-1, 1)));
}).add;

SynthDef(\sineCue, { |out = 0, freq = 440, amp = 0.2, dur = 1, atk = 0.005, rel = 0.06, gate = 1, cutoff = 20000, pan = 0, ampScale = 1|
	var ampEnv  = EnvGen.kr(Env([0, 1, 1, 0], [atk, (dur - atk).max(0.001), rel], [\sin, \lin, \sin]), doneAction: 2);
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2);
	var sig = LPF.ar(SinOsc.ar(freq), cutoff.clip(20, 20000)) * ampEnv * killEnv * amp * ampScale;
	Out.ar(out, Pan2.ar(sig, pan.clip(-1, 1)));
}).add;

SynthDef(\triCue, { |out = 0, freq = 440, amp = 0.2, dur = 1, atk = 0.005, rel = 0.06, gate = 1, cutoff = 20000, pan = 0, ampScale = 1|
	var ampEnv  = EnvGen.kr(Env([0, 1, 1, 0], [atk, (dur - atk).max(0.001), rel], [\sin, \lin, \sin]), doneAction: 2);
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2);
	var sig = LPF.ar(LFTri.ar(freq), cutoff.clip(20, 20000)) * ampEnv * killEnv * amp * ampScale;
	Out.ar(out, Pan2.ar(sig, pan.clip(-1, 1)));
}).add;

// Same arg contract as the siblings (note dur baked into a timed ampEnv that
// self-frees) PLUS velvet's own sharp/chaos/sat controls. `sat` morphs a stereo
// Ringz/PinkNoise "whistle" toward a Saw, driven into tanh and a resonant LPF
// whose cutoff gets a sharp-scaled percussive bump; `chaos` wiggles the pitch.
// ampEnv holds for `dur` then releases over `rel` and frees (so the note honors
// its length); killEnv keeps the fast cue-stop fade.
SynthDef(\velvetSawCue, { |out=0, freq=220, amp=0.2, dur=1, rel=0.3, gate=1, sharp=0.5, chaos=0, sat=0.3, pan=0, ampScale=0.5|
	var atk     = sharp.linexp(0, 1, 0.4, 0.002);
	var ampEnv  = EnvGen.kr(
		Env([0, 1, 0.78, 0], [atk, (dur - atk).max(0.001), rel], [\sin, -2, -2]),
		doneAction: 2);
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2);
	var fenv    = EnvGen.kr(Env.perc(0.001, 0.2 + (atk * 3)), gate);
	// chaos-driven freq wiggle, evaluated twice for a decorrelated stereo pair
	var wig     = { LFNoise2.kr(chaos.linexp(0, 1, 50, 300), mul: chaos * 0.25, add: 1) };
	var f       = [freq * wig.value, freq * wig.value];
	var whistle = Ringz.ar(PinkNoise.ar ! 2, f, 1 / (0.2 + (fenv / 5))) * 0.1;
	var sig     = XFade2.ar(whistle, Saw.ar(f), sat.linlin(0, 1, -1, 1));
	var drive   = 1 + (sat.pow(2) * 8);
	var cut     = (freq * (2 + (sat * 8)) * (1 + (fenv * (0.5 + (sharp * 6))))).clip(40, 18000);
	sig = (sig * drive).tanh / drive.sqrt;
	sig = RLPF.ar(sig, cut, 0.2);
	sig = sig * ampEnv * killEnv * amp * ampScale;
	Out.ar(out, Balance2.ar(sig[0], sig[1], pan));
}).add;


~makeSawStack = {
	|freq, chaos, gain|
	Splay.ar(
		Pulse.ar(
			[freq * 0.5, freq, freq * 1.5] * LFNoise2.kr(200, mul: chaos * 0.25, add: 1),
			mul: 0.2
		),
		0.3 + (0.6 * chaos), center: LFNoise2.kr(90, mul: chaos)
	) * gain;
};
~makeLorenzSinStack = {
	|lorenzRate, lorenzDepth, lorenzFreq, n=3|
	Mix(
		n.collect({|i|
			var freq = lorenzFreq * (i + 1);
			var sine = SinOsc.ar(
				LorenzL.ar([lorenzRate, lorenzRate * 1.01], mul:lorenzDepth, add:freq),
				mul:0.1
			);
			sine * (freq < (SampleRate.ir * 0.45)) * (1 / (i+1).pow(0.5));
		})
	);

};
~filterStack = { |src, filterFreq, chaos, sat|
	var bw      = chaos.linexp(0, 1, 0.05, 8);
	var resonz  = Resonz.ar(src, filterFreq, bw);
	XFade2.ar(src, resonz, 1 - sat);
};
~makeWhistle = { |freq, chaos, sat|
	var wiggleConstant = LFNoise2.kr(200, mul: chaos * 0.25, add: 1);
	Resonz.ar(WhiteNoise.ar, freq * wiggleConstant, 0.08);
};
~makeFilterFreq = { |freq, sharp, sat, gate|
	var fenv            = EnvGen.kr(Env.perc(0.001, 0.2 + (sharp.linexp(0, 1, 0.4, 0.004) * 3)), gate);
	var baseFilterFreq  = freq * (1 + (sat * 2));
	var filterEnvAmount = (0.5 + (sharp * 6)) * sat;
	(baseFilterFreq * (1 + (fenv * filterEnvAmount))).clip(40, 18000);
};
// Same arg contract as the siblings (note dur baked into a timed ampEnv that
// self-frees) PLUS its own sharp/chaos/sat controls. It previously used a GATED
// adsr (sustain 1.0) with no `dur`, so notes never honored their length and rang
// until the cue's group stopped -- and its long `rel` release was then chopped by
// ~stopCue's 0.2 s group reap (the documented \velvetSawCue bug). Now ampEnv
// holds for the full `dur` then releases over `rel` and self-frees; killEnv is
// the separate fast cue-stop fade.
SynthDef(\lorenzCue, {
	|out=0, freq=440, amp=0.2, dur=1, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0, ampScale=1|
	var attack = sharp.linexp(0, 1, 0.4, 0.004);
	var drive = 1 + (sat * 8);
	var dynamicEnv = EnvGen.kr(
		Env([0, 1, 1, 0], [attack, (dur - attack).max(0.001), rel], [\sin, \lin, -2]),
		doneAction: 2);
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2); // \gate->0 = fast cue-stop fade
	var chaosEnv = EnvGen.kr(Env.perc(attack/3, chaos/2, chaos/2)) + (chaos / 3);
	var lorenzDepth = chaosEnv * 500, lorenzRate = 5000;
	var lorenzFreq = freq;
	var filterFreq  = ~makeFilterFreq.(freq, sharp, sat, gate);
	var sawStack = ~makeSawStack.(freq, chaosEnv, sat * 3);
	var lorenzSin = ~makeLorenzSinStack.(lorenzRate, lorenzDepth, lorenzFreq);
	var whistle = ~makeWhistle.(freq, chaosEnv, sat * 3);
	var sig = sawStack + lorenzSin + whistle;
	sig = (~filterStack.(sig, lorenzFreq, chaosEnv, sat) + ~filterStack.(sig, filterFreq, chaosEnv, sat)) / 2;
	sig = sig * dynamicEnv * killEnv * amp * ampScale;
	//sig = (sig * drive).tanh / drive.sqrt;
	sig = sig * sat.linexp(0, 1, 10, 0.7);
	Out.ar(out, Balance2.ar(sig[0], sig[1], pan));
}).add;


// F3 continuous param control: a control-rate envelope writer. ~playCue plays one
// per (cue, track, param) curve, writing the (tempo-warped) value onto a control
// bus; note synths .map their matching control to that bus, so the param glides
// continuously (and DURING held notes), not just sampled once at onset. No
// doneAction -- it holds the env's final value until the cue's group is freed, so
// notes that start after the curve ends read its held last value (like tempo).
SynthDef(\paramBus, { |out = 0|
	Out.kr(out, EnvGen.kr(\env.kr(Env.newClear(512))));
}).add;


// ---------------------------------------------------------------------------
// State + tempo-envelope storage. ~tempoEnvs maps a key -> Env of BPM over
// (window) BEATS. Lookup tries the cue's name, then its file, then the default.
// ---------------------------------------------------------------------------
~masterAmp       = 0.25;
~cues            = [];                       // [ (name:, file:, path:, startBeat:, endBeat:, notes:) ]
~cueIndex        = 0;                         // cursor: index of the cue ~next will play
~playing         = nil;                       // (routine:, group:, index:)
~pendingClears   = 0;                         // clear-board (48) visual notes in the playing cue not yet fired
~clearChordDelta = 0.03;                      // s: a clear within this of a draw is "chorded" -> instant (no fade)
~tempoEnvs       = Dictionary.new;
~defaultTempoEnv = Env([120, 120], [1]);      // held at 120 BPM for the whole cue
~tempoMul        = 1.0;                        // global tempo scale for PRACTICE (0.5 = half speed, 2 = double); takes effect next ~play

// Per-cue volume level: a fixed amplitude multiplier on top of the velocity-amp
// and any amp curve. Keyed by 1-based cue number (matching the score / ~play).
// Loaded from levels.txt; missing cues default to 1.0 (~cueVolumeFor).
~cueLevels    = Dictionary.new;
~cueLevelPath = nil;                           // default levels config path (SETUP sets this)
~cueVolumeFor = { |index| ~cueLevels[index + 1] ? 1.0 };   // index is 0-based; cue numbers are 1-based

// ---------------------------------------------------------------------------
// F3 -- per-(cue, track, param) parameter curves. Keyed by a composite string
// "cue\ttrack\tparam" -> Env of the param value over (window) BEATS. track "*"
// means "all tracks of the cue". Tempo is NOT stored here (it is per-cue and
// lives in ~tempoEnvs); ~paramList names the non-tempo params, which must be
// control names the SynthDefs above declare (unknown names are ignored).
// ---------------------------------------------------------------------------
~paramEnvs   = Dictionary.new;
~paramKey    = { |cue, track, param| "%\t%\t%".format(cue, track, param) };
~paramList   = [\cutoff, \pan, \amp, \chaos, \sharp, \sat, \rel];
~paramRanges = (cutoff: [20, 20000], pan: [-1, 1], amp: [0, 1], chaos: [0, 1], sharp: [0, 1], sat: [0, 1], rel: [0.05, 6]);   // y-axis range per param (editor); each must contain the synth's default for that control

// Every param curve defined for this cue, as [ (track:, param:, env:), ... ]
// (track is "*" for an all-tracks curve, else the track-index string). ~playCue
// turns each into a control bus + writer synth.
~paramCurvesFor = { |cueName|
	var out = [];
	~paramEnvs.keysValuesDo({ |k, env|
		var p = k.split($\t);   // [cue, track, param]
		if(p[0] == cueName) {
			out = out.add((track: p[1], param: p[2].asSymbol, env: env));
		};
	});
	out;
};

// The SynthDef control a param actually drives: the amp curve scales velocity via
// the separate `ampScale` control; every other param drives the like-named control.
~paramControlName = { |param| if(param == \amp) { \ampScale } { param.asSymbol } };

// Introspect a SynthDef's declared default for a control, via its SynthDesc (added
// to SynthDescLib.global by `.add`). nil if the synth or control is unknown.
~synthControlDefault = { |synthName, control|
	var desc = SynthDescLib.global.at(synthName);
	desc !? {
		desc.controls.detect({ |c| c.name == control }) !? (_.defaultValue);
	};
};

// The value a freshly-created (track, param) curve should sit at: the declared
// default of the control the param drives, on the synth that track routes to. For
// track "*" (or an unmapped/ambiguous track), scan the cue's audio synths and take
// the first that declares the control; falls back to the param's range low.
~paramCurveDefault = { |cueName, track, param|
	var control = ~paramControlName.(param);
	var synthNames;
	if(track == "*") {
		var cue = ~cues.detect({ |c| c[\name] == cueName });
		synthNames = (cue ? (notes: [])) [\notes].collect(_[\track]).as(Set).asArray
			.collect({ |t| ~trackRoles[t] })
			.select({ |r| r.notNil and: { r[\role] == \audio } })
			.collect({ |r| r[\target] });
	} {
		var r = ~trackRoles[track.asInteger];
		synthNames = if(r.notNil and: { r[\role] == \audio }) { [r[\target]] } { [] };
	};
	synthNames.collect({ |sn| ~synthControlDefault.(sn, control) }).detect(_.notNil)
		?? { (~paramRanges[param] ? [0])[0] };
};

// Render a param curve (value over window BEATS) into a time-domain Env (value
// over SECONDS) by sampling it on a dense beat grid and warping each beat through
// the cue's tempo map -- mirroring ~buildTimeMap, so the drawn shape is rendered
// faithfully under whatever tempo curve is in force. The result is a plain \lin
// Env feeding the \paramBus writer (capped to maxSegments, the writer's reserve).
~warpParamEnv = { |env, map, maxSegments = 512|
	var dur = env.duration;
	if(dur <= 0) {
		Env([env.at(0), env.at(0)], [0.01], [\lin])    // degenerate: flat one-point curve
	} {
		var res    = (dur / maxSegments).max(0.02);
		var n      = (dur / res).ceil.asInteger.max(1);
		var beats  = Array.fill(n + 1, { |i| (i * res).min(dur) });
		var values = beats.collect({ |b| env.at(b) });
		var times  = beats.collect({ |b| ~beatToTime.(map, b) });
		var deltas = (1..n).collect({ |i| (times[i] - times[i - 1]).max(0) });
		Env(values, deltas, \lin)
	}
};

~trackRoles        = Dictionary.new;          // track index -> (role: \audio|\visual, target: synthdef symbol or \board)
~trackMapPath      = nil;                       // default track-map config path (SETUP sets this)

~midiMap           = Dictionary.new;          // "type chan num" -> action token (\next, \stop, or cue name)
~midiLearning      = nil;                      // action awaiting a control during MIDI-learn, else nil
~midiLearnSavePath = nil;                      // if set, save the map right after the next learn
~midiMapPath       = nil;                      // default config path (SETUP sets this)
~tempoEnvPath      = nil;                      // default tempo-envelope config path (SETUP sets this)

~tempoEnvFor = { |cue|
	~tempoEnvs[cue[\name]] ?? { ~tempoEnvs[cue[\file]] ?? { ~defaultTempoEnv } };
};

// Per-track routing. A track maps to (role: \audio, target: <synthdef>) or
// (role: \visual, target: \board). Tracks NOT listed in tracks.txt return nil --
// their notes are discarded (not played), not routed to a default voice.
~trackRoleFor = { |track|
	~trackRoles[track];
};

// Load tracks.txt:  one line  `track  role  target`  (e.g. `1 audio pulseCue`,
// `4 visual board`). '#' comments and blank lines ignored. Global to the piece.
~loadTrackMap = { |path|
	var p = path.standardizePath;
	if(File.exists(p)) {
		~trackRoles = Dictionary.new;
		File.readAllString(p).split($\n).do({ |line|
			var t = line.stripWhiteSpace.replace("\t", " ");
			if(t.notEmpty and: { t[0] != $# }) {
				var tok = t.split($ ).reject(_.isEmpty);
				if(tok.size >= 3) {
					~trackRoles[tok[0].asInteger] = (role: tok[1].asSymbol, target: tok[2].asSymbol);
				} {
					"loadTrackMap: skipping malformed line: %".format(line).warn;
				};
			};
		});
		"loaded % track mapping(s) from %".format(~trackRoles.size, p).postln;
	};
};

// ---------------------------------------------------------------------------
// Read notes from one MIDI file, windowed to [startBeat, endBeat). Onset must
// fall inside the window: notes starting earlier are dropped, notes ending past
// endBeat are truncated, and beats are re-zeroed to start. (endBeat inf => whole
// file.)
// ---------------------------------------------------------------------------
~midiDebug     = false;       // set true to dump each file's first 20 notes per track on load
~midiDebugSeen = Set.new;     // paths already dumped (so we print each file only once)

~readCueNotes = { |path, startBeat = 0, endBeat = inf|
	var m, div;
	// Guard: a missing .mid would make SimpleMIDIFile seek a never-opened handle
	// and throw the cryptic "instance of _FilePos failed". Warn and skip instead.
	if(File.exists(path).not) {
		"readCueNotes: MIDI file not found, skipping: %".format(path).warn;
		^[]
	};
	m   = SimpleMIDIFile.read(path);  // default timeMode == \ticks
	div = m.division;                 // ticks per quarter note

	// DEBUG: dump the RAW (un-windowed) first 20 notes of each track, once per file,
	// so you can see exactly which pitches each track carries (e.g. find the board track).
	if((~midiDebug == true) and: { ~midiDebugSeen.includes(path).not }) {
		var raw = m.noteSustainEvents;    // [track, absTime, \noteOn, chan, note, velo, dur, upVelo]
		var tracks = raw.collect({ |e| e[0] }).as(Set).asArray.sort;
		~midiDebugSeen.add(path);
		"[midi] % : division %, % note(s), tracks %".format(path.basename, div, raw.size, tracks).postln;
		tracks.do({ |tk|
			var es = raw.select({ |e| e[0] == tk });
			// each entry shown as  pitch@beat  (beat = absTime / division)
			"[midi]   track % (% notes): %".format(tk, es.size,
				es.keep(20).collect({ |e| "%@%".format(e[4], (e[1] / div).round(0.01)) })).postln;
		});
	};

	m.noteSustainEvents.collect({ |e|
		// e == [track, absTime, \noteOn, channel, note, velo, dur, upVelo]
		(startBeat: e[1] / div, durBeats: e[6] / div, midinote: e[4], vel: e[5], track: e[0])
	}).select({ |nt|
		(nt[\startBeat] >= startBeat) and: { nt[\startBeat] < endBeat }
	}).collect({ |nt|
		var s   = nt[\startBeat] - startBeat;                                // re-zero
		var end = (nt[\startBeat] + nt[\durBeats]).min(endBeat) - startBeat; // truncate
		(startBeat: s, durBeats: (end - s).max(0), midinote: nt[\midinote], vel: nt[\vel], track: nt[\track])
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
//   - filename is resolved relative to the midi/ directory (~midiDir, defaulting
//     to a sibling 'midi' folder of the cue sheet); no spaces.
//   - If no name is given the cue is labelled "filename [start-end]".
// ---------------------------------------------------------------------------
~loadCueSheet = { |sheetPath|
	var path    = sheetPath.standardizePath;
	var midiDir = (~midiDir ? (path.dirname +/+ "../midi")).standardizePath;
	~cues = [];
	File.readAllString(path).split($\n).do({ |line|
		var t = line.stripWhiteSpace.replace("\t", " ");
		if(t.notEmpty and: { t[0] != $# }) {
			var tok = t.split($ ).reject({ |x| x.isEmpty });
			if(tok.size >= 3) {
				var fname = tok[0];
				var base  = fname.basename;          // tempo-env fallback keys on the bare basename
				var sB    = tok[1].asFloat;
				var eB    = tok[2].asFloat;
				var label = if(tok.size > 3) { tok[3..].join(" ") }
				            { "% [%-%]".format(base, tok[1], tok[2]) };  // keep the text as written
				var p     = midiDir +/+ fname;
				~cues = ~cues.add(
					(name: label, file: base, path: p,
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
//   period(beat) = 60 / (BPM(beat) * ~tempoMul); time(beat) = cumulative trapezoid.
//   ~tempoMul is the global practice scale (1 = as written); it multiplies every BPM,
//   so the whole map (notes AND param curves, which warp through it) speeds/slows
//   together. Beyond the envelope's duration we hold the final BPM (clamp the query).
// ---------------------------------------------------------------------------
~buildTimeMap = { |env, maxBeat, resolution = 0.01|
	var mul     = (~tempoMul ? 1).max(0.01);
	var n       = (maxBeat / resolution).ceil.asInteger.max(1);
	var beats   = Array.fill(n + 1, { |i| i * resolution });
	var periods = beats.collect({ |b| 60 / (env.at(b.min(env.duration)) * mul) }); // sec per beat
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
		var buses = ~playing[\buses] ? [];
		~playing[\routine].stop;
		g.set(\gate, 0);                              // fade sounding voices, they self-free
		// reap the (now empty) group and free its param buses together, after the
		// fade -- freeing buses earlier could recycle an index the writer still drives.
		SystemClock.sched(0.2, { g.free; buses.do(_.free); nil });
		~playing = nil;
		// If the interrupted cue had a clear (48) signal -- one not yet fired, or
		// one already fired and still mid-fade -- snap the board to cleared NOW
		// (instant, dur 0) rather than leaving it half-drawn or mid-fade.
		if((~pendingClears > 0) or: { ~boardFadeRoutine.notNil }) {
			~boardEvent !? { ~boardEvent.((~boardClearPitch ? 48), 127, 0) };
		};
		~pendingClears = 0;
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
		var paramCurves, paramBuses, mapsForTrack, trackMapCache;

		~stopCue.value;

		env = ~tempoEnvFor.(cue);

		// F3 param curves of this cue (continuous control buses, built below).
		paramCurves = ~paramCurvesFor.(cue[\name]);

		lastBeat = if(cue[\notes].isEmpty) { 0 } {
			cue[\notes].collect({ |nt| nt[\startBeat] + nt[\durBeats] }).maxItem
		};
		// Cover the tempo env AND every param curve, so warping holds, not clips, late values.
		maxBeat = ([lastBeat, env.duration] ++ paramCurves.collect({ |pc| pc[\env].duration })).maxItem;
		map = ~buildTimeMap.(env, maxBeat);

		// Map each note's start/end beat through the integrated tempo curve, and
		// resolve its track's role/target (which synth to play, or \visual board).
		// Notes on tracks with no tracks.txt mapping (role nil) are discarded.
		events = cue[\notes].select({ |nt| ~trackRoleFor.(nt[\track]).notNil }).collect({ |nt|
			var t0   = ~beatToTime.(map, nt[\startBeat]);
			var t1   = ~beatToTime.(map, nt[\startBeat] + nt[\durBeats]);
			var role = ~trackRoleFor.(nt[\track]);
			(time: t0, dur: (t1 - t0).max(0.01), midinote: nt[\midinote], vel: nt[\vel],
				track: nt[\track], role: role[\role], target: role[\target])
		}).sort({ |a, b|
			// time order; at equal time a clear (visual 48) sorts FIRST, so a clear
			// chorded with a draw wipes the board before the new move is drawn.
			if(a[\time] == b[\time]) {
				var isClear = { |ev| (ev[\role] == \visual) and: { ev[\midinote] == (~boardClearPitch ? 48) } };
				isClear.(a) and: { isClear.(b).not }
			} {
				a[\time] < b[\time]
			};
		});

		// A clear (48) chorded with a draw -- another visual note at (nearly) the
		// same time -- must clear INSTANTLY so the move lands on a fresh board; a
		// lone clear still fades over its note length. Mark each such clear so the
		// routine passes the board dur 0 instead of ev[\dur].
		{
			var clearPitch = (~boardClearPitch ? 48);
			var drawTimes  = events.select({ |ev|
				(ev[\role] == \visual) and: { ev[\midinote] != clearPitch }
			}).collect(_[\time]);
			events.do({ |ev|
				if((ev[\role] == \visual) and: { ev[\midinote] == clearPitch }) {
					ev[\instantClear] = drawTimes.any({ |dt| (dt - ev[\time]).abs <= ~clearChordDelta });
				};
			});
		}.value;

		// Count clear-board (48) visual notes so a premature stop/interrupt can
		// finish the clear instantly (decremented as each one actually fires).
		~pendingClears = events.count({ |ev|
			(ev[\role] == \visual) and: { ev[\midinote] == (~boardClearPitch ? 48) }
		});

		// DEBUG: show how this cue's tracks resolved (audio synth vs visual board)
		// and how many visual events were scheduled -- the usual reason "the board
		// doesn't move" is that the track isn't actually mapped `visual board`.
		if(~boardDebug == true) {
			var tracks = cue[\notes].collect(_[\track]).as(Set).asArray.sort;
			var nVis   = events.count({ |ev| ev[\role] == \visual });
			"  [debug] cue '%' tracks present: %".format(cue[\name], tracks).postln;
			tracks.do({ |tk|
				var r       = ~trackRoleFor.(tk);
				var pitches = cue[\notes].select({ |nt| nt[\track] == tk }).collect(_[\midinote]);
				"  [debug]   track % -> %   first pitches: %".format(
					tk, if(r.isNil) { "(unmapped: discarded)" } { "% %".format(r[\role], r[\target]) },
					pitches.keep(10)).postln;
			});
			"  [debug] scheduled % visual + % audio event(s)".format(nVis, events.size - nVis).postln;
		};

		group = Group.new(s);

		// F3 continuous params: one control bus + writer synth per (track, param)
		// curve, keyed "track\tparam". Each writer plays the tempo-warped curve and
		// holds its last value (no doneAction) until the group is freed.
		paramBuses = Dictionary.new;
		paramCurves.do({ |pc|
			var bus    = Bus.control(s, 1);
			var warped = ~warpParamEnv.(pc[\env], map);
			paramBuses["%\t%".format(pc[\track], pc[\param])] = bus;
			Synth(\paramBus, [\out, bus.index, \env, warped.asArray], group);
		});

		// For a note's track, the [\param, busIndex] maps to apply: a track-specific
		// curve overrides the "*" (all-tracks) curve for the same param. Cached per track.
		trackMapCache = IdentityDictionary.new;
		mapsForTrack = { |tk|
			trackMapCache[tk] ?? {
				var list = [];
				paramCurves.collect(_[\param]).as(Set).do({ |pm|
					var b = paramBuses["%\t%".format(tk, pm)] ?? { paramBuses["*\t%".format(pm)] };
					// the amp curve drives ampScale (a multiplier on velocity-amp), not amp itself
					var ctl = ~paramControlName.(pm);
					b !? { list = list.add([ctl, b.index]) };
				});
				trackMapCache[tk] = list;
				list;
			};
		};

		routine = Routine({
			var now = 0;
			events.do({ |ev|
				(ev[\time] - now).wait;   // SystemClock => waits in seconds
				now = ev[\time];
				if(ev[\role] == \audio) {
					var syn = Synth(ev[\target], [
						\freq, ev[\midinote].midicps,
						\amp,  ~masterAmp * (ev[\vel] / 127).squared * ~cueVolumeFor.(index),
						\dur,  ev[\dur]
					], group);
					// F3: map this track's param controls to their continuous buses.
					mapsForTrack.(ev[\track]).do({ |m| syn.map(m[0], m[1]) });
				} {
					// F2 visualization: pitch -> board move. ~boardEvent defers to AppClock.
					if(ev[\role] == \visual) {
						if(~boardDebug == true) {
							"  [debug] visual note fired: pitch % vel % @ %.2f s".format(
								ev[\midinote], ev[\vel], ev[\time]).postln;
						};
						if(~boardEvent.isNil) { "  [debug] ~boardEvent is nil -- boardGui.scd not loaded?".postln };
						// ev[\dur] is the note's tempo-warped length, used by the board as
						// a clear's fade-out time -- but a clear chorded with a draw
						// (ev[\instantClear]) is passed dur 0 so it clears instantly and the
						// move lands on a fresh board.
						if(ev[\midinote] == (~boardClearPitch ? 48)) {
							~pendingClears = (~pendingClears - 1).max(0);   // this clear is now firing
						};
						~boardEvent !? {
							var bdur = if(ev[\instantClear] == true) { 0 } { ev[\dur] };
							~boardEvent.(ev[\midinote], ev[\vel], bdur);
						};
					};
				};
			});
			// Reached only on NATURAL completion -- a manual stop/interrupt halts the
			// routine first. The cursor already advanced at play-start, so just mark
			// stopped and reap the now-finished group after a short tail.
			~playing = nil;
			SystemClock.sched(1.0, { group.free; paramBuses.do(_.free); nil });
		}).play(SystemClock);

		~playing  = (routine: routine, group: group, index: index, buses: paramBuses.values.asArray);
		// Play-then-advance: the cursor moves forward as each cue STARTS, so tapping
		// ~next/~play while a cue is still sounding cuts it off and moves to the NEXT
		// cue. Only ~stop holds the cursor back (see ~stop).
		~cueIndex = (index + 1).min(~cues.size - 1);
		"playing cue [%] %  (%.2f s)".format(index, cue[\name], map.times.last).postln;
	};
};

// ---------------------------------------------------------------------------
// Play the cue at the cursor; ~playCue advances the cursor (play-then-advance) as the
// cue starts, so tapping this again mid-cue cuts it off and moves on to the next.
// ---------------------------------------------------------------------------
~playNext = {
	if(~cues.notEmpty) {
		~playCue.(~cueIndex);
	};
};

// ===========================================================================
// PERFORMER INTERFACE  (the names midi_cue_player.scd documents).
//   ~play.(id)  cue NAME ("1", "big finish", ...) or, failing that, a 1-based
//               cue number (matching the score; ~play.(1) is the first cue)
//   ~next.()    play the cue at the cursor and advance; tapping it (or ~play) while a
//               cue is still sounding cuts it off and moves on to the NEXT cue
//   ~stop.()    if sounding: fade out and STAY on this cue (so the next ~play/~next
//               restarts the same cue we stopped); if ALREADY stopped: step the
//               cursor back one more cue (no playback) to re-cue an earlier one
// ===========================================================================
~play = { |id|
	var idx = ~cues.detectIndex({ |c| c[\name] == id.asString });
	~playCue.(idx ? (id.asInteger - 1));   // no name match: id is a 1-based cue number
};

~next = ~playNext;

~stop = {
	if(~playing.notNil) {
		var idx = ~playing[\index];              // the cue we're cutting short
		~stopCue.value;                          // sounding -> fade out
		~cueIndex = idx;                          // ~stop does NOT advance: stay on this cue so ~next/~play replays it
	} {
		if(~cues.notEmpty) {                      // already stopped -> step the cursor back one more cue
			~cueIndex = (~cueIndex - 1).max(0);
			"stepped back -- next cue is [%] %".format(~cueIndex, ~cues[~cueIndex][\name]).postln;
		};
	};
};

// ===========================================================================
// INSPECTION  --  what tracks are present, with note counts and first pitches.
//   ~cueTracks.([id])   tracks of one cue's WINDOWED notes (default: the cursor
//                       cue, i.e. what ~next would play). id is a cue name or a
//                       1-based number, same as ~play.
//   ~fileTracks.([id])  tracks of that cue's WHOLE underlying MIDI file (un-
//                       windowed), useful to see everything before a cue carves
//                       its window out.
// Both print a summary and return the sorted list of track indices.
// ===========================================================================
~midiNoteName = { |n|
	var names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"];
	"%%".format(names[n % 12], n.div(12) - 1);    // 60 -> "C4"
};

~tracksReport = { |notes, label, firstN = 8|
	var tracks = notes.collect(_[\track]).as(Set).asArray.sort;
	"% : % note(s) across % track(s)".format(label, notes.size, tracks.size).postln;
	tracks.do({ |tk|
		var es     = notes.select({ |nt| nt[\track] == tk }).sort({ |a, b| a[\startBeat] < b[\startBeat] });
		var r      = ~trackRoleFor.(tk);
		var target = if(r.isNil) { "(unmapped: discarded)" } { r[\target] };
		var first  = es.keep(firstN).collect({ |nt| "%(%)".format(nt[\midinote], ~midiNoteName.(nt[\midinote])) });
		"  track % -> %: % note(s); first: %".format(tk, target, es.size, first).postln;
	});
	tracks;
};

~resolveCueIndex = { |id|
	if(id.isNil) { ~cueIndex } {                  // default: the cursor cue
		~cues.detectIndex({ |c| c[\name] == id.asString }) ?? { id.asInteger - 1 }
	};
};

~cueTracks = { |id|
	var i = ~resolveCueIndex.(id), cue = ~cues[i];
	if(cue.isNil) { "cueTracks: no cue for %".format(id ? "(cursor)").warn; nil } {
		~tracksReport.(cue[\notes], "cue [%] %".format(i + 1, cue[\name]));
	};
};

~fileTracks = { |id|
	var i = ~resolveCueIndex.(id), cue = ~cues[i];
	if(cue.isNil) { "fileTracks: no cue for %".format(id ? "(cursor)").warn; nil } {
		~tracksReport.(~readCueNotes.(cue[\path]), "file % (whole)".format(cue[\file]));
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

// Virtual ALSA-seq ports (PipeWire's mirror, "Midi Through"), the System
// Timer/Announce ports, and SuperCollider's own ports balloon the source list --
// MIDIIn.connectAll then stalls trying to connect all of them. Connect only real
// sources whose name/device matches none of these substrings.
~midiSkipPorts = ["Through", "PipeWire", "RtMidi", "SuperCollider", "Timer", "Announce"];

~midiConnectSources = {
	var n = 0;
	MIDIClient.sources.do({ |src|
		var label = (src.device ? "") ++ " " ++ (src.name ? "");
		if(~midiSkipPorts.any({ |w| label.containsi(w) }).not) {
			MIDIIn.connect(0, src);    // arg 1 is SC's input-port index (always 0), NOT the source index
			n = n + 1;
		};
	});
	"connected % MIDI source(s) (skipped virtual: %)".format(n, ~midiSkipPorts).postln;
};

~setupMIDI = {
	MIDIClient.init(verbose:false);
	~midiConnectSources.value;                 // selective connect (connectAll hangs on virtual ports)
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
// CUE VOLUME LEVELS  --  a per-cue amplitude multiplier, persisted to levels.txt
// as plain text, one binding per line:  `cueNum amplitude` (cueNum 1-based, to
// match ~play / the score). Missing cues default to 1.0 (~cueVolumeFor). This is
// applied ON TOP of the velocity-amp and any amp curve, in ~playCue.
//   ~setCueVolume.(7, 0.5)   set cue 7 to half volume AND persist to levels.txt
// ===========================================================================
~loadCueLevels = { |path|
	var p = path.standardizePath;
	if(File.exists(p)) {
		~cueLevels = Dictionary.new;
		File.readAllString(p).split($\n).do({ |line|
			var t = line.stripWhiteSpace;
			if(t.notEmpty and: { t[0] != $# }) {
				var tok = t.split($ ).reject(_.isEmpty);
				if(tok.size >= 2) {
					~cueLevels[tok[0].asInteger] = tok[1].asFloat;
				} {
					"loadCueLevels: skipping malformed line: %".format(line).warn;
				};
			};
		});
		"loaded % cue volume level(s) from %".format(~cueLevels.size, p).postln;
	};
};

~saveCueLevels = { |path|
	var p = path.standardizePath, f = File(p, "w");
	f.write("# cue volume levels -- one per line:  cueNum amplitude  (cueNum 1-based)\n");
	~cueLevels.keys.asArray.sort.do({ |k| f.write("% %\n".format(k, ~cueLevels[k])) });
	f.close;
	"saved % cue volume level(s) to %".format(~cueLevels.size, p).postln;
};

// Set one cue's volume (1-based cue number) and persist to ~cueLevelPath (if set).
~setCueVolume = { |cueNum, amplitude|
	~cueLevels[cueNum.asInteger] = amplitude.asFloat;
	"cue % volume set to %".format(cueNum, amplitude).postln;
	~cueLevelPath !? { |p| ~saveCueLevels.(p) };
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

// One persisted line: name | track | param | levels | durations | curves.
// Tempo envelopes are written with track "*" and param "tempo".
~envToLine = { |name, track, param, env|
	var curves = env.curves;
	if(curves.isArray.not) { curves = Array.fill(env.times.size.max(1), curves) };
	"% | % | % | % | % | %".format(
		name, track, param, env.levels.join(" "), env.times.join(" "), curves.join(" "));
};

~saveTempoEnvs = { |path|
	var p = path.standardizePath, f = File(p, "w"), n = 0;
	f.write("# curves:  name | track | param | bpm/value levels | beat durations | curves\n");
	f.write("#   param 'tempo' (track '*') = the cue's tempo curve; others = (cue, track, param)\n");
	~tempoEnvs.keysValuesDo({ |name, env| f.write(~envToLine.(name, "*", "tempo", env) ++ "\n"); n = n + 1 });
	~paramEnvs.keysValuesDo({ |k, env|
		var pp = k.split($\t);   // [cue, track, param]
		f.write(~envToLine.(pp[0], pp[1], pp[2], env) ++ "\n");  n = n + 1;
	});
	f.close;
	"saved % curve(s) (% tempo, % param) to %".format(n, ~tempoEnvs.size, ~paramEnvs.size, p).postln;
};

// Reads both the new 6-field format and the legacy 4-field tempo format
// (name | levels | durs | curves). Trailing 3 columns are always levels/durs/curves;
// a missing param column means 'tempo', a missing track column means '*' (all tracks).
~loadTempoEnvs = { |path|
	var p = path.standardizePath, nt = 0, np = 0;
	if(File.exists(p)) {
		File.readAllString(p).split($\n).do({ |line|
			var t = line.stripWhiteSpace;
			if(t.notEmpty and: { t[0] != $# }) {
				var parts = t.split($|).collect(_.stripWhiteSpace);
				var name, track = "*", param = "tempo", tail;
				case
					{ parts.size == 4 } { name = parts[0];                       tail = parts[1..3] }  // legacy tempo
					{ parts.size == 5 } { name = parts[0]; param = parts[1];     tail = parts[2..4] }  // name|param|...
					{ parts.size >= 6 } { name = parts[0]; track = parts[1]; param = parts[2]; tail = parts[3..5] };
				if(tail.notNil) {
					var levels = tail[0].split($ ).reject(_.isEmpty).collect(_.asFloat);
					var times  = tail[1].split($ ).reject(_.isEmpty).collect(_.asFloat);
					var curves = tail[2].split($ ).reject(_.isEmpty).collect({ |c| ~parseCurve.(c) });
					var env;
					if(curves.isEmpty) { curves = [\lin] };
					env = Env(levels, times, curves);
					if(param == "tempo") {
						~tempoEnvs[name] = env;  nt = nt + 1;
					} {
						~paramEnvs[~paramKey.(name, track, param)] = env;  np = np + 1;
					};
				} {
					"loadTempoEnvs: skipping malformed line: %".format(line).warn;
				};
			};
		});
		"loaded % tempo + % param curve(s) from %".format(nt, np, p).postln;
	};
};

"cue player engine loaded.".postln;
)
