#!/usr/bin/env python3
"""rpp_extract.py -- generate cues.txt + tempos.txt by parsing a Reaper .RPP file.

A dependency-free alternative to extract_cues.py: instead of driving Reaper via
reapy, it reads the project file directly. It pulls the project MARKERs and the
master tempo curve (<TEMPOENVEX> block), integrates the tempo curve to convert
everything from SECONDS to BEATS (quarter notes -- the engine's unit), and
writes the results to ./extracted/ so nothing in ../data is clobbered.

Cues: each marker starts a cue that runs until the NEXT marker, so N markers
yield N-1 windows (the final marker marks the end of the last cue).

Tempo: REAPER stores tempo points as linear-in-TIME ramps; this writes the same
BPM breakpoints as linear-in-BEAT segments (shape 0 -> `lin`, shape 1 -> `hold`),
which is a faithful starting point for the tempo GUI, not a sample-exact copy of
Reaper's micro-timing.

Usage:   python rpp_extract.py [--rpp MIDICues.RPP] [--midi MIDICues.mid]
                               [--out-dir ./extracted] [--dry-run]
"""

import argparse
import os
import shlex


# ----------------------------------------------------------------------------
def fmt(x, ndigits=4):
    r = round(float(x), ndigits)
    if r == int(r):
        return str(int(r))
    return ("%.*f" % (ndigits, r)).rstrip("0").rstrip(".")


# ----------------------------------------------------------------------------
# RPP parsing.
# ----------------------------------------------------------------------------
def parse_rpp(path):
    """Return (markers, tempo_points, default_bpm).

    markers      : [(time_sec, name)]
    tempo_points : [(time_sec, bpm, is_linear)]   (is_linear: shape 0 = ramp)
    default_bpm  : float from the project TEMPO line
    """
    markers = []
    tempo_points = []
    default_bpm = 120.0
    in_tempo = False

    with open(path) as f:
        for line in f:
            s = line.strip()
            if s.startswith("TEMPO "):
                # TEMPO <bpm> <num> <denom> [...]
                default_bpm = float(s.split()[1])
            elif s.startswith("MARKER "):
                tok = shlex.split(s)
                # MARKER <id> <pos> <name> ...   (regions reuse an id with an
                # end line; the point markers in this project are all distinct)
                markers.append((float(tok[2]), tok[3]))
            elif s.startswith("<TEMPOENVEX"):
                in_tempo = True
            elif in_tempo:
                if s == ">":
                    in_tempo = False
                elif s.startswith("PT "):
                    tok = s.split()
                    t = float(tok[1])
                    bpm = float(tok[2])
                    shape = int(float(tok[3])) if len(tok) > 3 else 1
                    tempo_points.append((t, bpm, shape == 0))

    markers.sort(key=lambda m: m[0])
    tempo_points.sort(key=lambda p: p[0])
    return markers, tempo_points, default_bpm


# ----------------------------------------------------------------------------
# Tempo curve in SECONDS, integrated to BEATS (quarter notes).
#   beats(t) = integral of bpm(tau)/60 dtau, 0..t
# ----------------------------------------------------------------------------
class SecondsTempo:
    def __init__(self, points, fallback_bpm):
        # points: [(time_sec, bpm, is_linear)]
        if not points:
            points = [(0.0, fallback_bpm, False)]
        elif points[0][0] > 0:
            points = [(0.0, points[0][1], False)] + points
        self.pts = points
        # cumulative beats at each point boundary
        self.cum = [0.0]
        for i in range(len(self.pts) - 1):
            self.cum.append(self.cum[-1] + self._seg_beats(i, self.pts[i + 1][0]))

    def _seg_beats(self, i, t_end):
        """Beats accumulated from pts[i] up to time t_end (within segment i)."""
        t0, v0, lin0 = self.pts[i]
        dt = t_end - t0
        if dt <= 0:
            return 0.0
        if lin0 and i + 1 < len(self.pts):
            t1, v1, _ = self.pts[i + 1]
            if t1 > t0:
                v_end = v0 + (v1 - v0) * (t_end - t0) / (t1 - t0)
                return (v0 + v_end) / 2.0 / 60.0 * dt   # linear ramp: mean bpm
        return v0 / 60.0 * dt                           # square / final: constant

    def beats_at(self, t):
        i = 0
        for j in range(len(self.pts)):
            if self.pts[j][0] <= t + 1e-12:
                i = j
            else:
                break
        return self.cum[i] + self._seg_beats(i, t)

    def beat_points(self):
        """The tempo curve re-expressed as (beat, bpm, is_linear) breakpoints."""
        return [(self.cum[i], v, lin) for i, (t, v, lin) in enumerate(self.pts)]


# ----------------------------------------------------------------------------
# BPM-over-BEATS curve, sliceable into per-cue envelopes (engine format).
# ----------------------------------------------------------------------------
class BeatTempo:
    EPS = 1e-9

    def __init__(self, beat_points):
        self.points = beat_points              # [(beat, bpm, is_linear)]

    def _governing(self, beat):
        idx = 0
        for i, (b, _, _) in enumerate(self.points):
            if b <= beat + self.EPS:
                idx = i
            else:
                break
        return idx

    def bpm_at(self, beat):
        i = self._governing(beat)
        b0, v0, lin0 = self.points[i]
        if i == len(self.points) - 1:
            return v0
        b1, v1, _ = self.points[i + 1]
        if lin0 and b1 > b0:
            return v0 + (v1 - v0) * (beat - b0) / (b1 - b0)
        return v0

    def slice(self, w0, w1):
        interior = sorted({b for (b, _, _) in self.points if w0 + self.EPS < b < w1 - self.EPS})
        nodes = [w0] + interior + [w1]
        levels = [round(self.bpm_at(n), 4) for n in nodes]
        durations = [nodes[j + 1] - nodes[j] for j in range(len(nodes) - 1)]
        curves = []
        for j in range(len(nodes) - 1):
            gi = self._governing(nodes[j])
            curves.append("lin" if self.points[gi][2] else "hold")
        return levels, durations, curves


# ----------------------------------------------------------------------------
def build_cues(marker_beats_named):
    """[(name, start_beat, end_beat)] -- marker to next marker (N-1 windows)."""
    cues = []
    for i in range(len(marker_beats_named) - 1):
        beat, name = marker_beats_named[i]
        nxt = marker_beats_named[i + 1][0]
        label = name if name else str(i + 1)
        cues.append((label, beat, nxt))
    return cues


def write_cues_file(path, midi_name, cues):
    lines = [
        "# Cue sheet for midi_cue_player.scd -- GENERATED by reaper/rpp_extract.py",
        "# One cue per line:   filename  start_beat  end_beat  [optional name]",
        "#   - filename is relative to the midi/ folder (just the bare name); no spaces",
        "#   - window is [start_beat, end_beat); beats are quarter notes, re-zeroed to start_beat",
    ]
    for name, sB, eB in cues:
        lines.append("%s   %s   %s   %s" % (midi_name, fmt(sB), fmt(eB), name))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def tempo_line(name, levels, durations, curves):
    return "%s | * | tempo | %s | %s | %s" % (
        name,
        " ".join(fmt(v, 4) for v in levels),
        " ".join(fmt(d) for d in durations),
        " ".join(curves),
    )


def write_tempos_file(path, cues, btempo):
    lines = [
        "# curves:  name | track | param | bpm/value levels | beat durations | curves",
        "#   tempo curves GENERATED from the Reaper master tempo by reaper/rpp_extract.py",
        "#   to use: copy this into data/tempos.txt -- doing so REPLACES any hand-drawn",
        "#   tempo and F3 param curves there, so merge by hand if you want to keep them.",
    ]
    for name, sB, eB in cues:
        lv, du, cu = btempo.slice(sB, eB)
        lines.append(tempo_line(name, lv, du, cu))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


# ----------------------------------------------------------------------------
def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Generate cues.txt / tempos.txt from a Reaper .RPP file.")
    ap.add_argument("--rpp", default=os.path.join(here, "MIDICues.RPP"),
                    help="path to the .RPP project (default: MIDICues.RPP next to this script)")
    ap.add_argument("--midi", default="MIDICues.mid",
                    help="MIDI filename written into cues.txt (default: MIDICues.mid)")
    ap.add_argument("--out-dir", default=os.path.join(here, "extracted"),
                    help="output directory (default: ./extracted next to this script)")
    ap.add_argument("--dry-run", action="store_true", help="print only, write no files")
    args = ap.parse_args()

    markers, tempo_points, default_bpm = parse_rpp(args.rpp)
    if len(markers) < 2:
        raise SystemExit("Need at least 2 markers to form a cue window; found %d." % len(markers))

    sec_tempo = SecondsTempo(tempo_points, default_bpm)
    btempo = BeatTempo(sec_tempo.beat_points())
    marker_beats = [(round(sec_tempo.beats_at(t), 4), name) for (t, name) in markers]
    cues = build_cues(marker_beats)

    print("%d marker(s) -> %d cue(s); default tempo %s bpm, %d tempo point(s)"
          % (len(markers), len(cues), fmt(default_bpm), len(tempo_points)))
    for name, sB, eB in cues:
        lv, _, _ = btempo.slice(sB, eB)
        print("  %-4s beat %-9s -> %-9s   tempo %s bpm"
              % (name, fmt(sB), fmt(eB), "/".join(fmt(v, 1) for v in lv)))

    if args.dry_run:
        print("\n[dry-run] no files written.")
        return

    os.makedirs(args.out_dir, exist_ok=True)
    cues_path = os.path.join(args.out_dir, "cues.txt")
    tempos_path = os.path.join(args.out_dir, "tempos.txt")
    write_cues_file(cues_path, args.midi, cues)
    write_tempos_file(tempos_path, cues, btempo)
    print("\nwrote %s\nwrote %s" % (cues_path, tempos_path))


if __name__ == "__main__":
    main()
