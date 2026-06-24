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
SynthDef(\sawCue, { |out = 0, freq = 440, amp = 0.2, dur = 1, atk = 0.005, rel = 4.5, gate = 1, cutoff = 3000, pan = 0, ampScale = 1|
	var ampEnv = EnvGen.kr(
		Env([0, 1, 1, 0], [atk, (dur - atk).max(0.001), rel], [\sin, \lin, \sin]),
		doneAction: 2
	);
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2); // \gate->0 = fast release
	var sig = LPF.ar(Saw.ar(freq), EnvGen.ar(Env.perc(0, 6)).linexp(0, 1, 50, 1000)) * ampEnv * killEnv * amp * ampScale;
	sig = sig * SinOsc.ar(EnvGen.ar(Env.perc(0,6)) * 15, mul: 0.4, add: 1);
	Out.ar(out, Pan2.ar(sig, pan.clip(-1, 1)));
}).add;

// Sibling voices: same arg contract as \sawCue, so any track can be routed to any of
// them via tracks.txt. Distinct waveforms only -- stand-ins, not realistic instruments.
SynthDef(\pulseCue, { |out = 0, freq = 440, amp = 0.1, dur = 1, atk = 0.005, rel = 0.06, gate = 1, cutoff = 20000, pan = 0, ampScale = 1|
	var ampEnv  = EnvGen.kr(Env([0, 1, 1, 0], [atk, (dur - atk).max(0.001), rel], [\sin, \lin, \sin]), doneAction: 2);
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2);
	var sig = LPF.ar(LPF.ar(Pulse.ar(freq, 0.35), freq * 6), cutoff.clip(20, 20000)) * ampEnv * killEnv * amp * ampScale;
	Out.ar(out, Pan2.ar(sig, pan.clip(-1, 1)));
}).add;

// \tremCue is a SAMPLE voice: it LOOPS the violin tremolo sounds/violintrem.wav
// (fundamental ~G4 / 392 Hz) transposed to the note's freq, under a gentle percussive
// amp envelope whose decay scales with `dur`, and a lowpass filter that sweeps from
// 4 kHz down to 30 Hz over `dur` (so the note darkens as it decays). The `cutoff`
// control CAPS that sweep (default 20000 = no cap), so an F3 cutoff curve can still
// pull it lower. ~playCue passes the loaded buffer as `buf` (see ~violinTremBuf below);
// like \metroCue it loops/plays the sample, not an oscillator.
SynthDef(\tremCue, { |out = 0, freq = 440, amp = 0.2, dur = 1, atk = 0.02, rel = 4.5, gate = 1, cutoff = 20000, pan = 0, ampScale = 1, buf = 0|
	var base    = 392;                                              // sample fundamental ~ G4
	var rate    = BufRateScale.kr(buf) * (freq / base);            // transpose to the note's pitch
	var src     = PlayBuf.ar(2, buf, rate, loop: 1);               // loop so notes longer than the sample sustain
	var attack  = (dur * 0.1).clip(atk, 0.4);                      // gentle attack, scales a little with dur
	var ampEnv  = EnvGen.kr(Env.perc(attack, dur + rel), doneAction: 2);  // percussive, decay ~ dur
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2);             // \gate->0 = fast cue-stop fade
	var fc      = min(EnvGen.kr(Env([4000, 30], [dur + rel], \exp)), cutoff);            // 4 kHz -> 30 Hz over dur, capped by cutoff
	var sig     = LPF.ar(src, fc.clip(20, 20000)) * ampEnv * killEnv * amp * ampScale;
	Out.ar(out, Balance2.ar(sig[0], sig[1], (pan + LFNoise1.kr(18, mul: 0.6)).clip(-1, 1)));
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
~getAmpEnv = {
	|sharp, rel, dur|
	var atk     = sharp.linexp(0, 1, 0.4, 0.002);
	var dec = sharp.linexp(0, 1, 0.3, 0.01).min(dur - atk);
	var sustLevel = sharp.linexp(0, 1, 0.75, 0.4);
	Env([0, 1, sustLevel, sustLevel, 0], [atk, dec, dur - atk - dec, rel], [\lin, \sin, \lin, -2]);
};
SynthDef(\velvetSawCue, { |out=0, freq=220, amp=0.2, dur=1, rel=0.3, gate=1, sharp=0.5, chaos=0, sat=0.3, pan=0, ampScale=0.5|
	var atk     = sharp.linexp(0, 1, 0.4, 0.002);
	var ampEnv  = EnvGen.kr(~getAmpEnv.(sharp, rel, dur), doneAction: 2);

	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2);
	var fenv    = EnvGen.kr(Env.perc(0.001, 0.2 + (atk * 3)), gate);
	// chaos-driven freq wiggle, evaluated twice for a decorrelated stereo pair
	var wig     = { LFNoise2.kr(chaos.linexp(0, 1, 50, 300), mul: chaos * 0.25, add: 1) };
	var f       = [freq * wig.value, freq * wig.value];
	var whistle = Ringz.ar(PinkNoise.ar ! 2, f, 1 / (0.2 + (fenv / 10))) * 0.1;
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


// Sample-playback voice: a pitched one-shot metronome click. Plays the single
// sample sounds/metroblock.wav at a playback rate of freq/440 -- 1x for A440 (the
// note A4), and the usual playback ratio higher for higher notes (so e.g. C5/E5
// give progressively higher-pitched clicks). Unlike the synth voices it ignores
// `dur` -- it plays the whole (rate-scaled) sample once and self-frees (PlayBuf
// doneAction 2). killEnv keeps the fast cue-stop fade. blockBuf is the loaded
// buffer, passed by ~playCue (see ~metroBlockBuf below). The sample is stereo.
SynthDef(\metroCue, { |out = 0, freq = 440, amp = 1.0, dur = 1, gate = 1, pan = 0, ampScale = 1, blockBuf = 0|
	var rate    = BufRateScale.kr(blockBuf) * (freq / 440);   // 1x at A440, pitched by freq ratio
	var sig     = PlayBuf.ar(2, blockBuf, rate, doneAction: 2);
	var killEnv = EnvGen.kr(Env.asr(0, 1, 0.02), gate, doneAction: 2);   // \gate->0 = fast cue-stop fade
	sig = sig * killEnv * amp * ampScale;
	Out.ar(out, Balance2.ar(sig[0], sig[1], pan.clip(-1, 1)));
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

// Sample buffer for \metroCue (loaded once, here, since the engine is executeFile'd
// only after the server has booted). ~playCue passes it to each \metroCue note.
// Path resolves relative to lib/ (this file). Stereo file.
~metroBlockBuf = Buffer.read(s, "sounds/metroblock.wav".resolveRelative);

// Sample buffer for \tremCue (the looping violin-tremolo voice), loaded once like
// ~metroBlockBuf. ~playCue passes it to each \tremCue note as `buf`. Stereo file.
~violinTremBuf = Buffer.read(s, "sounds/violintrem.wav".resolveRelative);


// ---------------------------------------------------------------------------
// State + tempo-envelope storage. ~tempoEnvs maps a key -> Env of BPM over
// (window) BEATS. Lookup tries the cue's name, then its file, then the default.
// ---------------------------------------------------------------------------
~masterAmp       = 0.25;
~ignoreVelocity  = true;                     // true => ignore MIDI velocity, play every note at full level (still scaled by ~masterAmp, cue levels, and amp curves)
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
~tempoEnvPath      = nil;                      // default tempo-curve config path (tempos.txt; SETUP sets this)
~otherCurvePath    = nil;                      // default param-curve config path (otherCurves.txt; SETUP sets this)

~tempoEnvFor = { |cue|
	~tempoEnvs[cue[\name]] ?? { ~tempoEnvs[cue[\file]] ?? { ~defaultTempoEnv } };
};

// Per-track routing. A track maps to (role: \audio, target: <synthdef>) or
// (role: \visual, target: \board). Tracks NOT listed in tracks.txt return nil --
// their notes are discarded (not played), not routed to a default voice.
~trackRoleFor = { |track|
	~trackRoles[track];
};

// Load tracks.txt:  one line  `track  role  target  [name...]`  (e.g.
// `1 audio pulseCue Bass`, `6 visual board`). The optional 4th+ tokens are a
// human-readable track name (may contain spaces) shown in the curve editor's
// track menu. '#' comments and blank lines ignored. Global to the piece.
~loadTrackMap = { |path|
	var p = path.standardizePath;
	if(File.exists(p)) {
		~trackRoles = Dictionary.new;
		File.readAllString(p).split($\n).do({ |line|
			var t = line.stripWhiteSpace.replace("\t", " ");
			if(t.notEmpty and: { t[0] != $# }) {
				var tok = t.split($ ).reject(_.isEmpty);
				if(tok.size >= 3) {
					~trackRoles[tok[0].asInteger] = (role: tok[1].asSymbol, target: tok[2].asSymbol,
						name: if(tok.size > 3) { tok[3..].join(" ") } { nil });
				} {
					"loadTrackMap: skipping malformed line: %".format(line).warn;
				};
			};
		});
		"loaded % track mapping(s) from %".format(~trackRoles.size, p).postln;
	};
};

// A track's display name from tracks.txt (4th column), falling back to its index
// as a string when none was given.
~trackName = { |track| (~trackRoles[track] !? (_[\name])) ?? { track.asString } };

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
			// A trailing "->" means: when this cue finishes (its window end), auto-
			// trigger the next cue. Stripped here so it doesn't pollute the name field.
			var autoNext = (tok.last == "->");
			if(autoNext) { tok = tok.drop(-1) };
			if(tok.size >= 3) {
				var fname = tok[0];
				var base  = fname.basename;          // tempo-env fallback keys on the bare basename
				var sB    = tok[1].asFloat;
				var eB    = tok[2].asFloat;
				var label = if(tok.size > 3) { tok[3..].join(" ") }
				            { "% [%-%]".format(base, tok[1], tok[2]) };  // keep the text as written
				var p     = midiDir +/+ fname;
				~cues = ~cues.add(
					(name: label, file: base, path: p, autoNext: autoNext,
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
		var cueLenBeats, cueEndTime;

		~stopCue.value;

		env = ~tempoEnvFor.(cue);

		// F3 param curves of this cue (continuous control buses, built below).
		paramCurves = ~paramCurvesFor.(cue[\name]);

		lastBeat = if(cue[\notes].isEmpty) { 0 } {
			cue[\notes].collect({ |nt| nt[\startBeat] + nt[\durBeats] }).maxItem
		};
		// The cue's WINDOW length (endBeat - startBeat), which may extend past the last
		// note. The routine waits to here before finishing, so the overlay/cursor advance
		// -- and any auto-follow handoff -- land at the true end of the cue, not the last
		// note. The time map must therefore cover the whole window, not just the notes.
		cueLenBeats = cue[\endBeat] - cue[\startBeat];
		// Cover the tempo env, every param curve, AND the window end, so warping holds
		// (not clips) late values.
		maxBeat = ([lastBeat, env.duration]
			++ paramCurves.collect({ |pc| pc[\env].duration })
			++ if(cueLenBeats != inf) { [cueLenBeats] } { [] }
		).maxItem;
		map = ~buildTimeMap.(env, maxBeat);
		// Seconds from cue start to its window end (nil for an open-ended whole-file cue).
		cueEndTime = if(cueLenBeats != inf) { ~beatToTime.(map, cueLenBeats) } { nil };

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
					var syn, args = [
						\freq, ev[\midinote].midicps,
						\amp,  ~masterAmp * (if(~ignoreVelocity == true) { 1 } { (ev[\vel] / 127).squared }) * ~cueVolumeFor.(index),
						\dur,  ev[\dur]
					];
					// \metroCue is a sample player: hand it the loaded block buffer, which
					// it plays back pitched by the note's freq (1x at A440).
					if(ev[\target] == \metroCue) {
						args = args ++ [\blockBuf, ~metroBlockBuf];
					};
					// \tremCue loops the violin-tremolo sample: hand it that buffer as `buf`.
					if(ev[\target] == \tremCue) {
						args = args ++ [\buf, ~violinTremBuf];
					};
					syn = Synth(ev[\target], args, group);
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
			// Every note is launched (we're at the last note's ONSET). Hold until the
			// cue's WINDOW end before finishing, so the cursor/overlay advance -- and any
			// auto-follow handoff -- land at the true end of the cue, not the last note.
			// This wait lives INSIDE the routine, so ~stopCue (which stops the routine)
			// cancels it: a stopped cue never advances the overlay or auto-follows.
			if(cueEndTime.notNil) { (cueEndTime - now).max(0).wait };
			// Window finished NATURALLY (a manual stop/interrupt halted the routine above).
			// Mark stopped, advance the overlay to the next cue (the cursor), and -- if
			// auto-follow -- start it. ~playing is cleared first so ~playNext's ~stopCue is
			// a no-op and the release tails ring on into the next cue. Reap after a tail.
			~playing = nil;
			~boardCueIndex = ~cueIndex;
			if(~boardShowCueNum == true) { { ~boardDraw.value }.defer };
			if((cue[\autoNext] == true) and: { (index + 1) < ~cues.size }) {
				~playNext.value;
			};
			SystemClock.sched(1.0, { group.free; paramBuses.do(_.free); nil });
		}).play(SystemClock);

		~playing  = (routine: routine, group: group, index: index, buses: paramBuses.values.asArray);
		// Play-then-advance: the cursor moves forward as each cue STARTS, so tapping
		// ~next/~play while a cue is still sounding cuts it off and moves to the NEXT
		// cue. Only ~stop holds the cursor back (see ~stop).
		~cueIndex = (index + 1).min(~cues.size - 1);
		"playing cue %".format(index + 1).postln;
		// Board cue-number overlay: show the cue that just STARTED (not the advanced
		// cursor), and keep it until the NEXT cue starts -- so it holds through this
		// cue's trailing silence/release tail and an auto-follow handoff.
		~boardCueIndex = index;
		if(~boardShowCueNum == true) { { ~boardDraw.value }.defer };
		// Crisscross grid: every cue EXCEPT the first and last shows it, so jumping
		// straight to a middle cue isn't left grid-less (a 49/47 note in the cue can
		// still fade it out/in afterwards). The first cue fades it in, the last out.
		if((index > 0) and: { index < (~cues.size - 1) }) {
			~boardFadeGrid !? { { ~boardFadeGrid.(1, 0) }.defer };
		};
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

// Print where the cursor now sits ("on cue 7"). Called whenever the cursor moves
// without playing (~goToCue, ~stop step-back, arrow-key shifts). Cue numbers are
// 1-based to match the score / ~play.
~announceCue = {
	~cues[~cueIndex] !? { "on cue %".format(~cueIndex + 1).postln };
	// the cursor moved without playing -> the board overlay follows it
	~boardCueIndex = ~cueIndex;
	if(~boardShowCueNum == true) { { ~boardDraw.value }.defer };
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

// Move the cursor to a cue WITHOUT playing it (so the next ~next/~play starts
// there). `id` is a cue NAME or, failing a name match, a 1-based cue number --
// same resolution as ~play.
~goToCue = { |id|
	var idx = ~cues.detectIndex({ |c| c[\name] == id.asString }) ?? { id.asInteger - 1 };
	if(idx.isNil or: { idx < 0 } or: { idx >= ~cues.size }) {
		"goToCue: no cue for %".format(id).warn;
	} {
		~cueIndex = idx;
		~announceCue.value;
	};
};

// Step the cursor by `delta` cues WITHOUT playing (clamped to the cue range),
// announcing the new position. Drives the board's left/right arrow keys.
~shiftCue = { |delta|
	if(~cues.notEmpty) {
		~cueIndex = (~cueIndex + delta).clip(0, ~cues.size - 1);
		~announceCue.value;
	};
};

~stop = {
	if(~playing.notNil) {
		var idx = ~playing[\index];              // the cue we're cutting short
		~stopCue.value;                          // sounding -> fade out
		~cueIndex = idx;                          // ~stop does NOT advance: stay on this cue so ~next/~play replays it
		~announceCue.value;
	} {
		if(~cues.notEmpty) {                      // already stopped -> step the cursor back one more cue
			~cueIndex = (~cueIndex - 1).max(0);
			~announceCue.value;
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
// CURVE PERSISTENCE  --  save/load the drawn curves as plain text. TEMPO curves
// live in tempos.txt (~tempoEnvPath); all the other (cue, track, param) curves
// live in otherCurves.txt (~otherCurvePath) -- two files so the tempo map stays
// independent of the F3 param curves. One line per curve:
//     <cue name> | <track> | <param> | <levels> | <beat durations> | <curves>
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

// Tempo curves only -> tempos.txt (each written track "*", param "tempo").
~saveTempoEnvs = { |path|
	var p = path.standardizePath, f = File(p, "w");
	f.write("# tempo curves:  name | * | tempo | bpm levels | beat durations | curves\n");
	~tempoEnvs.keysValuesDo({ |name, env| f.write(~envToLine.(name, "*", "tempo", env) ++ "\n") });
	f.close;
	"saved % tempo curve(s) to %".format(~tempoEnvs.size, p).postln;
};

// Non-tempo (cue, track, param) curves only -> otherCurves.txt.
~saveOtherCurves = { |path|
	var p = path.standardizePath, f = File(p, "w");
	f.write("# param curves:  name | track | param | value levels | beat durations | curves\n");
	~paramEnvs.keysValuesDo({ |k, env|
		var pp = k.split($\t);   // [cue, track, param]
		f.write(~envToLine.(pp[0], pp[1], pp[2], env) ++ "\n");
	});
	f.close;
	"saved % param curve(s) to %".format(~paramEnvs.size, p).postln;
};

// Save BOTH curve files (the curve editor's "save all"): tempo -> ~tempoEnvPath,
// the rest -> ~otherCurvePath. Skips a file whose path isn't set.
~saveCurves = {
	~tempoEnvPath   !? { |p| ~saveTempoEnvs.(p) }  ?? { "saveCurves: ~tempoEnvPath not set.".warn };
	~otherCurvePath !? { |p| ~saveOtherCurves.(p) } ?? { "saveCurves: ~otherCurvePath not set.".warn };
};

// Load a curve file (tempos.txt OR otherCurves.txt -- each line is routed to the
// right dictionary by its param field, so a file may hold either or, for an old
// combined tempos.txt, both). Reads the new 6-field format and the legacy 4-field
// tempo format (name | levels | durs | curves); trailing 3 columns are always
// levels/durs/curves; a missing param means 'tempo', a missing track means '*'.
~loadCurves = { |path|
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
					"loadCurves: skipping malformed line: %".format(line).warn;
				};
			};
		});
		"loaded % tempo + % param curve(s) from %".format(nt, np, p).postln;
	};
};

// Back-compat alias: the loader used to be named ~loadTempoEnvs.
~loadTempoEnvs = ~loadCurves;

"cue player engine loaded.".postln;
)
