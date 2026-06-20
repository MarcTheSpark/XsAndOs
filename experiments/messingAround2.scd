(
{ var f = 220, chaos = MouseX.kr(0, 1);
  var wob = LFNoise2.kr(8) * 0.07 + LFNoise2.kr(20) * 0.04 +  LFNoise2.kr(40) * 0.02;
  var mf = f * (1 + (wob * chaos));
  Pan2.ar(RLPF.ar(Saw.ar(mf) * 0.2, 2000, 0.3), 0)
}.play;
)

MarcUtilities.setOutputLimiter(0.5, 0.5)

(
{ var f = 220, chaos = MouseX.kr(0, 1);
  var lz = LorenzL.ar(SampleRate.ir * 0.3, s: 10, r: chaos.linlin(0, 1, 16, 28), b: 2.6);
  var mf = f * (1 + (LeakDC.ar(lz) * 0.012 * chaos));
  Pan2.ar(RLPF.ar(Saw.ar(mf) * 0.2, 2000, 0.3), 0)
}.play;
)

(
{
	MouseX.kr(8, 12).poll(label:"x");
	MouseY.kr(18, 58).poll(label:"y");
	LorenzL.ar(
    SampleRate.ir,
	MouseX.kr(8, 12),
    MouseY.kr(18, 58),
    0.5,
) * 0.2 }.play(s);
)
(
{ var f = 220, chaos = MouseX.kr(0, 1);0
  var lg = Logistic.ar(chaos.linlin(0, 1, 3.5, 3.99)!2, 200, 0.5) - 0.5;
  var mf = f * (1 + (LPF.ar(lg, 40) * 5 * chaos));
  RLPF.ar(Saw.ar(mf) * 0.2, 2000, 0.3)
}.play;
)

(
{
	var lorenz = LorenzL.ar(
		SampleRate.ir,
		MouseX.kr(8.5, 10),
		40,
		0.5,
	) * 0.2;
	Convolution.ar(lorenz, Saw.ar(440));
}.play(s);BPF
)



// ADD ENVELOPES!

(
{
	var freq = MouseX.kr(300, 1000, warp: \exponential);
	var chaos = MouseY.kr;
	var lorenzDepth = chaos * 500, lorenzRate = 5000;
	var lorenzFreq = freq; // * 0.74324 * 2 * 2/3;
	var sawStack = Splay.ar(
		Pulse.ar([freq * 0.5, freq, freq * 1.5] * WhiteNoise.kr(chaos * 0.3 ! 3, 1), mul: 0.2),
		0.6, center: LFNoise2.kr(90, mul: chaos)
	) * 0.3;
	var lorenzSin = SinOsc.ar(LorenzL.ar([lorenzRate, lorenzRate * 1.01], mul:lorenzDepth, add:lorenzFreq), mul:0.1);
	//RHPF.ar(lorenzSin, lorenzFreq, 0.01);
	BPF.ar(sawStack + lorenzSin, lorenzFreq, chaos.linexp(0, 1, 0.05, 4), mul:3); // bigger Q here = more chaotic
}.play
)

440/592

(
var getLorenz = {|rate, s| LorenzL.ar(rate, s, 40, 0.5) * 0.2;};
{
	var note = MouseX.kr(44, 80);                 // play it like a keyboard
    var s    = MouseY.kr(8.5, 10);                // your effect/character knob
    var refNote = 68;                             // the Ab you hear at SampleRate.ir (Ab4 = 68)
    var rate = SampleRate.ir * (note - refNote).midiratio;
	var stereo = [getLorenz.(rate, s), getLorenz.(rate, s+0.1)];
	// Convolution.ar(stereo, Saw.ar(note.midicps));
	var bpfNoise = Resonz.ar(WhiteNoise.ar, freq:note.midicps, bwr: 0.001, mul: 1.5);
	(note - refNote).midiratio.poll;
	stereo + [bpfNoise, Delay2.ar(bpfNoise)];
}.play;
)