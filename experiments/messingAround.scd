(
{
	|freq = 200|
	var modIndex = MouseX.kr.linexp(0, 1, 0.01, 300);
	var fb = LocalIn.ar(1);
	var fbNoise = fb; //(fb + LFNoise2.kr(40));
	var sig = SinOsc.ar(freq + (PlayBuf.ar(2, b) * modIndex));
	modIndex.poll;
	LocalOut.ar(sig);
	sig !2 * 0.3;
}.play
)

MarcUtilities.setOutputLimiter(0.5, 0.5)

~fat = Buffer.read(s, "sounds/859149__cat-fox_alex__brazilianfunk-fatty-kick-3.flac".resolveRelative);

~bone = Buffer.read(s, "sounds/bone.wav".resolveRelative);

~bone.play
(
{
	(SinOsc.ar(2, mul:0.5, add:0.5) * BufFrames.ir(~bone)).poll;
	BufRd.ar(2, ~fat, Saw.ar(MouseX.kr.linexp(0, 1, 0.2, 220), mul:0.5, add:0.5) * BufFrames.ir(~fat));
}.play
)

// Simple version - plays at variable rate
{ PlayBuf.ar(2, ~bone, BufRateScale.ir(~bone) * MouseX.kr.linexp(0, 1, 0.25, 4), loop: 1) }.play

(
// Or BufRd with Phasor for more control
{
    var rate = BufRateScale.ir(~bone) * MouseX.kr.linexp(0, 1, 0.25, 200);
    var phase = Phasor.ar(0, rate, 0, BufFrames.ir(~fat));
    var read = BufRd.ar(2, ~fat, phase);
	read;
}.play
)