MarcUtilities.setOutputLimiter(0.5, 0.5)

(
var makeSawStack = {
	|freq, chaos, gain|
	Splay.ar(
		Pulse.ar(
			[freq * 0.5, freq, freq * 1.5] * WhiteNoise.kr(chaos * 0.3 ! 3, 1),
			mul: 0.2
		),
		0.6, center: LFNoise2.kr(90, mul: chaos)
	) * gain;
};
{
	|freq=440, gate=1, sharp=0.5, chaos=0|
	var lorenzDepth = chaos * 500, lorenzRate = 5000;
	var lorenzFreq = freq; // * 0.74324 * 2 * 2/3;
	var sawStack = makeSawStack.(freq, chaos, sharp * 3);
	var lorenzSin = SinOsc.ar(LorenzL.ar([lorenzRate, lorenzRate * 1.01], mul:lorenzDepth, add:lorenzFreq), mul:0.1);
	BPF.ar(sawStack + lorenzSin + PinkNoise.ar(0.1), lorenzFreq, chaos.linexp(0, 1, 0.05, 8), mul:3); // bigger Q here = more chaotic
}.play
)




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
	~filterStack = { |src, filterFreq, chaos, nHarmonics=5|
		Mix(
			nHarmonics.collect({|i|
				var freq = filterFreq * (i + 1);
				var bw = chaos.linexp(0, 1, 0.05, 8);
				BPF.ar(src, freq, bw) * (freq < (SampleRate.ir * 0.45)) * 200 / freq;
			})
		) * 2;
	};
	SynthDef(\marc, {
		|out=0, freq=440, amp=0.2, gate=1, sharp=0.5, chaos=0, sat=0.3, rel=0.8, pan=0|
		var attack = sharp.linexp(0, 1, 0.4, 0.004);
		var dynamicEnv = EnvGen.kr(Env.adsr(attack, 0.3, 1.0, rel), gate, doneAction: 2);
		var chaosEnv = EnvGen.kr(Env.perc(attack/3, chaos/2, chaos/2)) + (chaos / 3);
		var lorenzDepth = chaosEnv * 500, lorenzRate = 5000;
		var lorenzFreq = freq; // * 0.74324 * 2 * 2/3;
		var sawStack = ~makeSawStack.(freq, chaosEnv, sat * 3);
		var lorenzSin = ~makeLorenzSinStack.(lorenzRate, lorenzDepth, lorenzFreq);
		var sig = sawStack + lorenzSin;
		sig = ~filterStack.(sig, lorenzFreq, chaosEnv);
		sig = sig * dynamicEnv * amp;
		Out.ar(out, Pan2.ar(sig, pan));
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