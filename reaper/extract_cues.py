#!/usr/bin/env python3
"""extract_cues.py -- generate cues.txt (and tempos.txt) from a Reaper project.

Each project MARKER starts a cue that runs until the next marker (or the end of
the project). Positions are read on Reaper's musical timeline as quarter notes,
which is exactly the "beat" unit the SuperCollider engine uses (beat =
ticks / division for a MIDI file). The cue windows are written to `cues.txt` in
the format the engine's ~loadCueSheet reads:

    filename  start_beat  end_beat  [name]

Optionally (default on) the master TEMPO CURVE is sliced per cue and written to
`tempos.txt` in the engine's curve format:

    name | * | tempo | bpm-levels | beat-durations | curves

Reaper tempo points map to envelope segments: a "linear" point ramps (`lin`),
a non-linear / "square" point holds its value until the next point (`hold`).

Output goes to `./extracted/` next to this script (NOT straight into ../data),
so it never clobbers the live config -- review the files, then copy them over.

----------------------------------------------------------------------------
Requires the `python-reapy` package:  pip install python-reapy

Run it either way -- reapy works in both:
  * INSIDE Reaper:  Actions list > "ReaScript: Run reaScript (EEL, lua or python)"
                    > pick this file. (Reaper's Python must be configured.)
  * OUTSIDE Reaper: enable the reapy dist API once -- inside Reaper run
                    `import reapy; reapy.configure_reaper()`, restart Reaper --
                    then from a shell:  python extract_cues.py
----------------------------------------------------------------------------
"""

import argparse
import os
import sys

try:
    from reapy import reascript_api as RPR
except ImportError:
    sys.exit(
        "extract_cues.py needs python-reapy (`pip install python-reapy`).\n"
        "It works both inside Reaper and, with the dist API enabled, from a shell."
    )

PROJ = 0  # the active project, in ReaScript terms

# ----------------------------------------------------------------------------
# Number formatting: keep whole beats integer-looking ("20" not "20.0").
# ----------------------------------------------------------------------------
def fmt(x, ndigits=6):
    r = round(float(x), ndigits)
    if r == int(r):
        return str(int(r))
    return ("%.*f" % (ndigits, r)).rstrip("0").rstrip(".")


# ----------------------------------------------------------------------------
# Reaper readers (quarter-note positions == engine beats).
# ----------------------------------------------------------------------------
def time_to_beats(seconds):
    return RPR.RPR_TimeMap2_timeToQN(PROJ, seconds)


def read_markers():
    """Return [(beat, name)] for every project marker (regions excluded), sorted."""
    # RPR_CountProjectMarkers -> (total, proj, num_markers, num_regions)
    total = RPR.RPR_CountProjectMarkers(PROJ, 0, 0)[0]
    markers = []
    for i in range(total):
        # -> (retval, proj, idx, isrgn, pos, rgnend, name, markrgnindexnumber)
        _, _, _, isrgn, pos, _, name, _ = RPR.RPR_EnumProjectMarkers2(
            PROJ, i, 0, 0, 0, "", 0
        )
        if not isrgn:
            markers.append((time_to_beats(pos), name.strip()))
    markers.sort(key=lambda m: m[0])
    return markers


def project_end_beat():
    return time_to_beats(RPR.RPR_GetProjectLength(PROJ))


def read_tempo_points():
    """Return [(beat, bpm, is_linear)] for the master tempo curve, sorted by beat."""
    n = RPR.RPR_CountTempoTimeSigMarkers(PROJ)
    pts = []
    for i in range(n):
        # -> (retval, proj, idx, timepos, measurepos, beatpos, bpm, num, denom, linear)
        res = RPR.RPR_GetTempoTimeSigMarker(PROJ, i, 0, 0, 0, 0, 0, 0, 0)
        timepos, bpm, linear = res[3], res[6], bool(res[9])
        pts.append((time_to_beats(timepos), bpm, linear))
    pts.sort(key=lambda p: p[0])
    return pts


# ----------------------------------------------------------------------------
# Master tempo curve, queryable and sliceable into per-cue envelopes.
# ----------------------------------------------------------------------------
class TempoMap:
    EPS = 1e-9

    def __init__(self, points, fallback_bpm):
        self.points = points            # [(beat, bpm, is_linear)]
        self.fallback = fallback_bpm

    def _governing(self, beat):
        """Index of the last tempo point at or before `beat` (-1 if none)."""
        idx = -1
        for i, (b, _, _) in enumerate(self.points):
            if b <= beat + self.EPS:
                idx = i
            else:
                break
        return idx

    def bpm_at(self, beat):
        if not self.points:
            return self.fallback
        i = self._governing(beat)
        if i < 0:
            return self.points[0][1]            # before the first point: hold it
        b0, v0, lin0 = self.points[i]
        if i == len(self.points) - 1:
            return v0                            # after the last point: hold it
        b1, v1, _ = self.points[i + 1]
        if lin0 and b1 > b0:
            return v0 + (v1 - v0) * (beat - b0) / (b1 - b0)
        return v0                                # non-linear: hold left value

    def slice(self, w0, w1):
        """(levels, durations, curves) for the window [w0, w1], re-zeroed to w0."""
        if not self.points:
            return [self.fallback, self.fallback], [w1 - w0], ["lin"]
        interior = sorted({b for (b, _, _) in self.points if w0 + self.EPS < b < w1 - self.EPS})
        nodes = [w0] + interior + [w1]
        levels = [round(self.bpm_at(n), 4) for n in nodes]
        durations = [nodes[j + 1] - nodes[j] for j in range(len(nodes) - 1)]
        curves = []
        for j in range(len(nodes) - 1):
            gi = self._governing(nodes[j])
            is_linear = self.points[gi][2] if gi >= 0 else True
            curves.append("lin" if is_linear else "hold")
        return levels, durations, curves


# ----------------------------------------------------------------------------
# Build cues from markers.
# ----------------------------------------------------------------------------
def build_cues(markers, end_beat):
    """[(name, start_beat, end_beat)] -- each marker to the next (or project end)."""
    cues = []
    for i, (beat, name) in enumerate(markers):
        nxt = markers[i + 1][0] if i + 1 < len(markers) else end_beat
        label = name if name else str(i + 1)
        cues.append((label, beat, nxt))
    return cues


# ----------------------------------------------------------------------------
# Writers.
# ----------------------------------------------------------------------------
def write_cues_file(path, midi_name, cues):
    lines = [
        "# Cue sheet for midi_cue_player.scd -- GENERATED by reaper/extract_cues.py",
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


def write_tempos_file(path, cues, tmap):
    lines = [
        "# curves:  name | track | param | bpm/value levels | beat durations | curves",
        "#   tempo curves GENERATED from the Reaper master tempo by reaper/extract_cues.py",
        "#   to use: copy this into data/tempos.txt -- doing so REPLACES any hand-drawn",
        "#   tempo and F3 param curves there, so merge by hand if you want to keep them.",
    ]
    for name, sB, eB in cues:
        levels, durations, curves = tmap.slice(sB, eB)
        lines.append(tempo_line(name, levels, durations, curves))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


# ----------------------------------------------------------------------------
def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.join(here, "extracted")

    ap = argparse.ArgumentParser(description="Generate cues.txt / tempos.txt from the open Reaper project.")
    ap.add_argument("--midi", default="MIDICues.mid",
                    help="MIDI filename written into cues.txt (default: MIDICues.mid)")
    ap.add_argument("--out-dir", default=default_out,
                    help="directory for cues.txt / tempos.txt (default: ./extracted next to this script)")
    ap.add_argument("--no-tempo", action="store_true",
                    help="skip the tempo curve (write cues.txt only)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be written, touch no files")
    args = ap.parse_args()

    markers = read_markers()
    if not markers:
        sys.exit("No project markers found -- nothing to extract. Add markers in Reaper first.")

    end_beat = project_end_beat()
    cues = build_cues(markers, end_beat)
    tmap = TempoMap(read_tempo_points(), RPR.RPR_Master_GetTempo())

    cues_path = os.path.join(args.out_dir, "cues.txt")
    tempos_path = os.path.join(args.out_dir, "tempos.txt")

    print("%d cue(s) from %d marker(s); project end at beat %s" % (len(cues), len(markers), fmt(end_beat)))
    for name, sB, eB in cues:
        line = "  %-16s %s -> %s" % (name, fmt(sB), fmt(eB))
        if not args.no_tempo:
            lv, du, cu = tmap.slice(sB, eB)
            line += "   tempo %s bpm" % "/".join(fmt(v, 1) for v in lv)
        print(line)

    if args.dry_run:
        print("\n[dry-run] no files written.")
        return

    os.makedirs(args.out_dir, exist_ok=True)
    write_cues_file(cues_path, args.midi, cues)
    print("\nwrote %s" % cues_path)
    if not args.no_tempo:
        write_tempos_file(tempos_path, cues, tmap)
        print("wrote %s" % tempos_path)


if __name__ == "__main__":
    main()
