// ============================================================================
// synthOptions.scd  --  a timbre EXPLORATION lab (not wired into the cue player).
//
// Evaluate this whole block once (cursor inside the outer "(" ... ")", Ctrl+Enter).
// It boots the server if needed, adds a small library of pitched SynthDefs that
// all share ONE expressive control contract, and opens a GUI to audition them.
//
// Shared control contract (every synth understands all of these):
//   freq   pitch in Hz
//   amp    level 0..1
//   gate   1 = on, 0 = release (the GUI manages this)
//   sharp  0..1  SHARPNESS of attack + brightness (1 = fast, bright, present)
//   chaos  0..1  CHAOTICNESS: noise, jitter, inharmonicity, stochastic motion
//   sat    0..1  FLUTY <-> SATURATED: 0 = pure/hollow tone, 1 = rich/overdriven
//   rel    release time in seconds
//   pan    -1..1
//
// The six voices interpret that contract through different synthesis methods, so
// the same three "feel" knobs (sharp/chaos/sat) give a different palette each:
//   \velvetSaw   subtractive saw<->sine morph + tanh drive + resonant filter
//   \fmGlass     2-operator FM (sat = mod index, chaos = ratio/noise jitter)
//   \gendyStream Xenakis dynamic stochastic synthesis (Gendy1) -- very chaotic
//   \breathFlute additive flute w/ breath noise + vibrato (sat adds reediness)
//   \shaperVox   wavefolding / waveshaping (sat = fold depth) + Crackle chaos
//   \pluckChaos  Karplus-Strong PLUCKED string (sat = brightness/drive, chaos = ring mod)
//   \bowString   BOWED synth-strings ensemble (detuned saws + body filter + vibrato)
// ============================================================================

MarcUtilities.setOutputLimiter(1, 0.5)
{}.play
{BPF.ar(PinkNoise.ar,1000, 0.001) * 5}.play
(
s = s ? Server.default;
s.waitForBoot({

	~wigFreq = {
		|freq, chaos|
		var wiggleConstant = LFNoise2.kr(chaos.linexp(0, 1, 50, 300), mul: chaos * 0.25, add: 1);
		freq * wiggleConstant;
	};
	// ------------------------------------------------------------------ defs
	// 1) Subtractive: morph sine->saw with `sat`, drive into tanh, resonant LPF
	//    whose cutoff gets a percussive bump scaled by `sharp`.
	SynthDef(\velvetSaw, { |out=0, freq=220, amp=0.2, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0|
		var atk   = sharp.linexp(0, 1, 0.4, 0.002);
		var env   = EnvGen.kr(Env.adsr(atk, 0.25, 0.78, rel, curve: -2), gate, doneAction: 2);
		var fenv  = EnvGen.kr(Env.perc(0.001, 0.2 + (atk * 3)), gate);
		var wiggleConstant = LFNoise2.kr(chaos.linexp(0, 1, 50, 300), mul: chaos * 0.25, add: 1);
		var f     = [~wigFreq.(freq, chaos), ~wigFreq.(freq, chaos)];
		var whistle = Ringz.ar(PinkNoise.ar ! 2, f, 1/(0.2 + (fenv / 5))) * 0.1;// * sat.linexp(0, 1, 3, 0.7);
		var sig   = XFade2.ar(whistle, Saw.ar(f), sat.linlin(0, 1, -1, 1));
		var drive = 1 + (sat.pow(2) * 8);
		var cut   = (freq * (2 + (sat * 8)) * (1 + (fenv * (0.5 + (sharp * 6))))).clip(40, 18000);
		sig = (sig * drive).tanh / drive.sqrt;
		sig = RLPF.ar(sig, cut, 0.2);// + (chaos * 0.5));
		sig = sig * env * amp;
		Out.ar(out, Balance2.ar(sig[0], sig[1], pan));
	}).add;

	SynthDef(\velvetSawOriginal, { |out=0, freq=220, amp=0.2, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0|
		var atk   = sharp.linexp(0, 1, 0.4, 0.002);
		var env   = EnvGen.kr(Env.adsr(atk, 0.25, 0.78, rel, curve: -2), gate, doneAction: 2);
		var f     = LFNoise2.kr(200, env * chaos * 30, add: freq);// * LFNoise2.ar(201, 0.01, 1.0);
		var osc   = XFade2.ar(SinOsc.ar(f), Saw.ar(f), sat.linlin(0, 1, -1, 1));
		var drive = 1 + (sat * 8);
		var fenv  = EnvGen.kr(Env.perc(0.001, 0.2 + (atk * 3)), gate);
		var cut   = (freq * (2 + (sat * 8)) * (1 + (fenv * (0.5 + (sharp * 6))))).clip(40, 18000);
		osc = (osc * drive).tanh / drive.sqrt;
		osc = RLPF.ar(osc, cut, 0.2);// + (chaos * 0.5));
		Out.ar(out, Pan2.ar(osc * env * amp, pan));
	}).add;

	// 2) 2-op FM. sat raises modulation index (more sidebands), chaos jitters the
	//    ratio and injects noisy FM, sharp shortens attack + boosts index.
	SynthDef(\fmGlass, { |out=0, freq=220, amp=0.2, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0|
		var atk   = sharp.linexp(0, 1, 0.4, 0.002);
		var env   = EnvGen.kr(Env.adsr(atk, 0.3, 0.7, rel), gate, doneAction: 2);
		var menv  = EnvGen.kr(Env.perc(0.001, 0.4 + rel), gate);
		var ratio = (1 + (sat * 2)) + (LFNoise1.kr(6) * (chaos * 1.5));
		var index = (sat * 12) + (sharp * 4);
		var mod   = SinOsc.ar(freq * ratio.abs) * freq * index * (0.4 + (menv * 0.6));
		var car;
		mod = mod + (LFNoise2.ar(freq * ratio.abs) * freq * index * chaos * 0.4);
		car = SinOsc.ar(freq + mod);
		Out.ar(out, Pan2.ar(car * env * amp, pan));
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
	SynthDef(\marc, {
		|out=0, freq=440, amp=0.2, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0|
		var attack = sharp.linexp(0, 1, 0.4, 0.004);
		var drive = 1 + (sat * 8);
		var dynamicEnv = EnvGen.kr(Env.adsr(attack, 0.3, 1.0, rel), gate, doneAction: 2);
		var chaosEnv = EnvGen.kr(Env.perc(attack/3, chaos/2, chaos/2)) + (chaos / 3);
		var lorenzDepth = chaosEnv * 500, lorenzRate = 5000;
		var lorenzFreq = freq;
		var filterFreq  = ~makeFilterFreq.(freq, sharp, sat, gate);
		var sawStack = ~makeSawStack.(freq, chaosEnv, sat * 3);
		var lorenzSin = ~makeLorenzSinStack.(lorenzRate, lorenzDepth, lorenzFreq);
		var whistle = ~makeWhistle.(freq, chaosEnv, sat * 3);
		var sig = sawStack + lorenzSin + whistle;
		sig = (~filterStack.(sig, lorenzFreq, chaosEnv, sat) + ~filterStack.(sig, filterFreq, chaosEnv, sat)) / 2;
		sig = sig * dynamicEnv * amp;
		sig = (sig * drive).tanh / drive.sqrt;
		sig = sig * sat.linexp(0, 1, 10, 0.7);
		Out.ar(out, Balance2.ar(sig[0], sig[1], pan));
	}).add;

	// 3) Gendy1 dynamic stochastic synthesis. chaos drives the distribution shape
	//    + amplitude/duration scaling; sat lowers the control-point count toward
	//    noisier territory. Naturally alive/unstable.
	SynthDef(\gendyStream, { |out=0, freq=220, amp=0.2, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0|
		var atk  = sharp.linexp(0, 1, 0.4, 0.004);
		var env  = EnvGen.kr(Env.adsr(atk, 0.3, 0.8, rel), gate, doneAction: 2);
		var knum = sat.linlin(0, 1, 12, 3).round;
		var g    = Gendy1.ar(
			ampdist:  2, durdist: 3,
			adparam:  chaos.clip(0.0001, 1.0), ddparam: chaos.clip(0.0001, 1.0),
			minfreq:  freq, maxfreq: freq * (1 + (chaos * 0.5) + sat),
			ampscale: 0.3 + (chaos * 0.6), durscale: 0.1 + (chaos * 0.5),
			initCPs:  12, knum: knum);
		g = LPF.ar(g, (freq * 4 * (1 + (sharp * 4))).clip(80, 18000));
		Out.ar(out, Pan2.ar(g * env * amp * 0.6, pan));
	}).add;

	// 4) Flute-ish additive: pure-ish tone at sat 0 (sine + faint partials), going
	//    reedy/saturated as sat rises (added harmonics + saw). chaos = breath/air
	//    turbulence + vibrato wander; sharp = attack chiff + brightness.
	SynthDef(\breathFlute, { |out=0, freq=220, amp=0.2, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0|
		var atk    = sharp.linexp(0, 1, 0.5, 0.01);
		var env    = EnvGen.kr(Env.adsr(atk, 0.2, 0.95, rel, curve: 1), gate, doneAction: 2);
		var vib    = SinOsc.kr(5 + (LFNoise1.kr(2) * (chaos * 3))) * (0.008 + (chaos * 0.02));
		var f      = freq * (1 + vib);
		var chiff  = EnvGen.kr(Env.perc(0.01, 0.25 + atk), gate);
		var breath = BPF.ar(WhiteNoise.ar, (f * 2).clip(80, 18000), 0.5) * (0.2 + (chaos * 0.6)) * chiff;
		var tone   = SinOsc.ar(f)
		             + (SinOsc.ar(f * 2) * sat * 0.5)
		             + (SinOsc.ar(f * 3) * sat * sharp * 0.3)
		             + (Saw.ar(f) * sat.squared * 0.4);
		var sig    = tone + (breath * 0.5) + (LFNoise2.ar(f) * chaos * 0.08);
		sig = RLPF.ar(sig, (f * (3 + (sat * 6)) * (1 + sharp)).clip(80, 18000), 0.6);
		Out.ar(out, Pan2.ar(sig * env * amp * 0.5, pan));
	}).add;

	// 5) Wavefolding / waveshaping. sat = fold depth (clean -> screaming harmonics),
	//    chaos = pitch jitter + Crackle (chaotic map) grit, sharp = pulse width +
	//    brightness. Final tanh tames the peaks.
	SynthDef(\shaperVox, { |out=0, freq=220, amp=0.2, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0|
		var atk = sharp.linexp(0, 1, 0.4, 0.002);
		var env = EnvGen.kr(Env.adsr(atk, 0.25, 0.8, rel), gate, doneAction: 2);
		var jit = LFNoise2.kr(10 + (chaos * 30)) * (chaos * 0.06);
		var src = VarSaw.ar(freq * (1 + jit), 0, 0.1 + (sharp * 0.4));
		var sig = (src * (1 + (sat * 12))).fold2(1);
		sig = sig + (Crackle.ar(1.5 + (chaos * 0.4)) * chaos * 0.2 * env);
		sig = LPF.ar(sig, (freq * (3 + (sat * 6)) * (1 + (sharp * 3))).clip(80, 18000));
		Out.ar(out, Pan2.ar(sig.tanh * env * amp * 0.5, pan));
	}).add;

	// 6) Karplus-Strong plucked string. sharp = excitation brightness, sat = string
	//    coefficient (brightness/sustain) + drive, chaos = noisy excitation + a
	//    chaotic ring-mod tail. Percussive but pitched.
	SynthDef(\pluckChaos, { |out=0, freq=220, amp=0.2, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0|
		var env   = EnvGen.kr(Env.asr(0.001, 1, rel * 2), gate, doneAction: 2);
		var exc   = (WhiteNoise.ar(0.3 + (sharp * 0.7)) + (Dust2.ar(200 * chaos) * chaos))
		            * EnvGen.kr(Env.perc(0.0005, 0.02 + (sharp * 0.05)));
		var coef  = sat.linlin(0, 1, 0.1, 0.5);
		var str   = Pluck.ar(exc, Impulse.kr(0), 0.2, (1 / freq).clip(0.0005, 0.2), (rel * 4) + 1, coef);
		str = (str * (1 + (sat * 6))).tanh;
		str = str + (str * SinOsc.ar(freq * (2 + chaos)) * chaos * 0.3);
		Out.ar(out, Pan2.ar(str * env * amp, pan));
	}).add;

	// 7) Bowed string / synth-strings ensemble. A small detuned-saw section through
	//    a resonant body filter, with vibrato and an attack bow-scratch. sat = bow
	//    pressure (harmonics + drive), chaos = scratchiness + detune spread (more
	//    voices = lusher/looser), sharp = attack speed + brightness. Sustained/arco,
	//    a counterpart to the plucked pluckChaos.
	SynthDef(\bowString, { |out=0, freq=220, amp=0.2, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0|
		var atk    = sharp.linexp(0, 1, 0.6, 0.01);                 // bowed = gentle onset
		var env    = EnvGen.kr(Env.adsr(atk, 0.2, 0.9, rel, curve: 1), gate, doneAction: 2);
		var vib    = SinOsc.kr(5 + LFNoise1.kr(0.5).range(-0.3, 0.3)) * (0.005 + (chaos * 0.02));
		var f      = freq * (1 + vib);
		var spread = 0.002 + (chaos * 0.02);
		var saws   = Mix([-1, 0, 1].collect({ |d| Saw.ar(f * (1 + (d * spread))) })) / 3;
		var scratch= BPF.ar(WhiteNoise.ar, (f * 4).clip(80, 18000), 0.6)
		             * ((chaos * 0.4) + 0.05) * EnvGen.kr(Env.perc(0.02, 0.2 + atk), gate) * (0.5 + sharp);
		var drive  = 1 + (sat * 6);
		var cut    = (freq * (3 + (sat * 8)) * (1 + (sharp * 3))).clip(80, 18000);
		var sig    = RLPF.ar(((saws + scratch) * drive).tanh, cut, 0.4);
		sig = sig + (BPF.ar(sig, 400, 0.5) * 0.3) + (BPF.ar(sig, 2000, 0.4) * 0.2);   // body resonances
		Out.ar(out, Pan2.ar(sig * env * amp * 0.5, pan));
	}).add;

	s.sync;

	// --------------------------------------------------------------- lab state
	~synthOptionDefs = [\velvetSaw, \marc, \fmGlass, \gendyStream, \breathFlute, \shaperVox, \pluckChaos, \bowString];
	~synthLabCurrent = ~synthOptionDefs[0];
	~synthLabState   = (freq: 220, amp: 0.2, sharp: 0.5, chaos: 0.0, sat: 0.3, rel: 0.8, pan: 0);
	~synthLabKeys    = [\freq, \amp, \sharp, \chaos, \sat, \rel, \pan];
	~synthLabSynth   = nil;   // the sustaining test voice (nil when silent)

	~synthLabArgs = { ~synthLabKeys.collect({ |k| [k, ~synthLabState[k]] }).flatten };

	~synthLabPlayShort = {
		var syn = Synth(~synthLabCurrent, ~synthLabArgs.value ++ [\gate, 1]);
		SystemClock.sched(0.18, { syn.set(\gate, 0); nil });   // brief note
	};
	~synthLabRelease = {
		~synthLabSynth !? { |sy| sy.set(\gate, 0) };
		~synthLabSynth = nil;
	};
	~synthLabHold = {
		~synthLabRelease.value;
		~synthLabSynth = Synth(~synthLabCurrent, ~synthLabArgs.value ++ [\gate, 1]);
	};

	// --------------------------------------------------------------------- GUI
	~openSynthLab = {
		var w  = Window("Synth Options Lab", Rect(200, 200, 440, 410));
		var specs = [
			[\freq,  ControlSpec(40, 4000, \exp, 0, 220, " Hz")],
			[\amp,   ControlSpec(0, 1, \amp, 0, 0.2)],
			[\sharp, ControlSpec(0, 1, \lin, 0, 0.5)],
			[\chaos, ControlSpec(0, 1, \lin, 0, 0.0)],
			[\sat,   ControlSpec(0, 1, \lin, 0, 0.3)],
			[\rel,   ControlSpec(0.05, 6, \exp, 0, 0.8, " s")],
			[\pan,   ControlSpec(-1, 1, \lin, 0, 0)]
		];
		var y = 46;
		StaticText(w, Rect(12, 12, 52, 24)).string_(" synth:");
		PopUpMenu(w, Rect(66, 12, 250, 24))
			.items_(~synthOptionDefs.collect(_.asString))
			.value_(~synthOptionDefs.indexOf(~synthLabCurrent))
			.action_({ |m| ~synthLabCurrent = ~synthOptionDefs[m.value] });

		specs.do({ |spc|
			var key = spc[0];
			EZSlider(w, Rect(12, y, 416, 26), key.asString, spc[1],
				{ |ez|
					~synthLabState[key] = ez.value;
					~synthLabSynth !? { |sy| sy.set(key, ez.value) };   // live update if sustaining
				},
				~synthLabState[key], labelWidth: 56, numberWidth: 72);
			y = y + 32;
		});

		y = y + 8;
		Button(w, Rect(12, y, 130, 36)).states_([["test short"]])
			.action_({ ~synthLabPlayShort.value });
		Button(w, Rect(150, y, 160, 36))
			.states_([["test sustained", Color.black, Color.new(0.6, 0.85, 0.6)],
			          ["release",        Color.white, Color.new(0.8, 0.3, 0.3)]])
			.action_({ |b| if(b.value == 1) { ~synthLabHold.value } { ~synthLabRelease.value } });
		Button(w, Rect(318, y, 110, 36)).states_([["panic"]])
			.action_({ ~synthLabRelease.value; s.defaultGroup.release });

		w.onClose = { ~synthLabRelease.value };
		w.front;
	};

	{ ~openSynthLab.value }.defer;
	"Synth Options Lab ready -- % voices: %".format(~synthOptionDefs.size, ~synthOptionDefs).postln;
});
)
