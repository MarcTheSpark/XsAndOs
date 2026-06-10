#!/usr/bin/env python3
"""
process_visual_midi.py  --  highlight tic-tac-toe wins in the visual-board MIDI.

Reads MIDIVisual.mid (the "visual board" track: pitches 60-68 = X, 72-80 = O,
48 = clear, 47/49 = grid fade in/out), walks it note by note while tracking board
state, and writes MIDIVisualProcessed.mid with the SAME notes plus a few more so
that winning lines and the final tableau are drawn "in colour" (velocity >= 127, the
board's win threshold -- MIDI velocity is 7-bit so 127 is the max, used in place of the
requested 255).

What it adds / changes (nothing else about the old notes changes):
  * 3-in-a-row: when a move completes a line, that completing note-on's velocity is
    bumped to 127 in place, and the line's OTHER two squares get fresh velocity-127
    note-ons at the same tick (their original marks were placed earlier), so all three
    light up together at the moment the line completes.
  * Final tableau: at the very last moment where X and O play the centre together, a
    full velocity-127 colour redraw of every square is added (owners taken from the
    final game's board state; the centre, pitch 64 + 76, is drawn as BOTH X and O),
    so the whole board lights up and stays lit until the grid fades out.
"""

import mido

SRC = "MIDIVisual.mid"
DST = "MIDIVisualProcessed.mid"

WIN_VEL = 127        # board colours any cell with velocity >= 127 (MIDI 7-bit max)
ADD_DUR = 120        # tick length of every note-on we add (the board only acts on note-on)

LINES = [(0, 1, 2), (3, 4, 5), (6, 7, 8),     # rows
         (0, 3, 6), (1, 4, 7), (2, 5, 8),     # cols
         (0, 4, 8), (2, 4, 6)]                # diagonals

CLEAR_PITCH = 48
X_BASE, O_BASE = 60, 72                        # square = pitch - base (0..8)


def decode(pitch):
    """-> ('X'|'O', base, square) for a move pitch, else (None, None, None)."""
    if X_BASE <= pitch <= X_BASE + 8:
        return ("X", X_BASE, pitch - X_BASE)
    if O_BASE <= pitch <= O_BASE + 8:
        return ("O", O_BASE, pitch - O_BASE)
    return (None, None, None)


def main():
    mf = mido.MidiFile(SRC)

    # The visual track is the one that actually carries notes (track 0 is tempo/meta).
    vt_index = next(i for i, t in enumerate(mf.tracks)
                    if any(m.type == "note_on" for m in t))
    track = mf.tracks[vt_index]
    channel = next((m.channel for m in track if m.type == "note_on"), 0)

    # Absolute-tick view of the track, message objects copied so we can edit in place.
    abs_events = []      # [ [tick, msg], ... ]  (original order preserved)
    t = 0
    for msg in track:
        t += msg.time
        abs_events.append([t, msg.copy()])

    # Note-ons in time order, with their index into abs_events (so we can bump a velocity).
    moves = [(tick, idx, msg.note)
             for idx, (tick, msg) in enumerate(abs_events)
             if msg.type == "note_on" and msg.velocity > 0]

    clear_ticks = [tick for tick, _, p in moves if p == CLEAR_PITCH]
    xo_moves = [(tick, idx, p) for tick, idx, p in moves if decode(p)[0]]
    final_tick = max(tick for tick, _, _ in xo_moves)
    last_clear_before_final = max([c for c in clear_ticks if c < final_tick], default=-1)

    PMAP = {"X": 1, "O": 2}
    vel_edits = {}        # abs_events idx -> new velocity (completing moves)
    added = []            # (tick, pitch, vel) note-ons to insert
    wins = []             # (tick, player, completing_sq, winning_squares) for the report

    # --- pass 1: walk the game, detect each newly-completed line -------------------
    state = [0] * 9       # 0 empty, 1 X, 2 O
    for tick, idx, p in moves:
        if p == CLEAR_PITCH:
            state = [0] * 9
            continue
        who, base, sq = decode(p)
        if who is None:                  # grid fades / stray pitches: no board change
            continue
        pl = PMAP[who]
        state[sq] = pl                   # a later move overwrites the cell, as the board does
        win_sqs = set()
        for line in LINES:               # only lines through the just-placed square can be NEW
            if sq in line and all(state[c] == pl for c in line):
                win_sqs.update(line)
        if win_sqs:
            wins.append((tick, who, sq, sorted(win_sqs)))
            vel_edits[idx] = WIN_VEL                 # completing move -> colour, in place
            for w in win_sqs:
                if w != sq:                          # the other squares -> added colour notes
                    added.append((tick, base + w, WIN_VEL))

    # --- final tableau: colour every square at the last X+O-centre moment ----------
    # Owners come from the final game's board state (moves after the last clear before
    # the final tick); the centre is drawn as BOTH X and O.
    fstate = [0] * 9
    for tick, idx, p in xo_moves:
        if last_clear_before_final < tick <= final_tick:
            who, base, sq = decode(p)
            fstate[sq] = PMAP[who]
    tableau = []
    for sq in range(9):
        if sq == 4:
            continue                                  # centre handled as both, below
        if fstate[sq] == 1:
            tableau.append(X_BASE + sq)
        elif fstate[sq] == 2:
            tableau.append(O_BASE + sq)
    tableau += [X_BASE + 4, O_BASE + 4]               # centre: both X and O
    for pitch in tableau:
        added.append((final_tick, pitch, WIN_VEL))

    # --- apply the in-place velocity bumps -----------------------------------------
    for idx, v in vel_edits.items():
        abs_events[idx][1].velocity = v

    # --- rebuild the track: originals + added, sorted by tick, end_of_track last ----
    orig_end_tick = max(tick for tick, msg in abs_events if msg.type == "end_of_track")
    # (tick, priority, order, msg); priority 1 = added, so added notes fall AFTER the
    # originals at the same tick (e.g. after a clear -> they redraw on a fresh board).
    bag = []
    for order, (tick, msg) in enumerate(abs_events):
        if msg.type != "end_of_track":
            bag.append((tick, 0, order, msg))
    for j, (tick, pitch, vel) in enumerate(added):
        on = mido.Message("note_on", note=pitch, velocity=vel, channel=channel, time=0)
        off = mido.Message("note_off", note=pitch, velocity=0, channel=channel, time=0)
        bag.append((tick, 1, 1_000_000 + 2 * j, on))
        bag.append((tick + ADD_DUR, 1, 1_000_000 + 2 * j + 1, off))
    bag.sort(key=lambda e: (e[0], e[1], e[2]))

    out = mido.MidiTrack()
    prev = 0
    for tick, _, _, msg in bag:
        m = msg.copy()
        m.time = tick - prev
        prev = tick
        out.append(m)
    end_tick = max(prev, orig_end_tick)
    out.append(mido.MetaMessage("end_of_track", time=end_tick - prev))

    new_mf = mido.MidiFile(ticks_per_beat=mf.ticks_per_beat, type=mf.type)
    for i, tr in enumerate(mf.tracks):
        new_mf.tracks.append(out if i == vt_index else tr)
    new_mf.save(DST)

    # --- report --------------------------------------------------------------------
    orig_on = len(moves)
    new_on = sum(1 for m in out if m.type == "note_on" and m.velocity > 0)
    print(f"source note-ons: {orig_on}   output note-ons: {new_on}   (+{new_on - orig_on})")
    print(f"velocity bumps (completing moves -> {WIN_VEL}): {len(vel_edits)}")
    print(f"3-in-a-row events detected: {len(wins)}")
    for tick, who, sq, sqs in wins:
        print(f"   tick {tick:7d}  {who} completes square {sq}  ->  line {sqs}")
    owners = {sq: ("X" if fstate[sq] == 1 else "O" if fstate[sq] == 2 else ".") for sq in range(9)}
    print(f"final tableau @ tick {final_tick}: owners "
          f"{[owners[s] for s in range(9)]} (centre drawn both X and O)")
    print(f"wrote {DST}")


if __name__ == "__main__":
    main()
