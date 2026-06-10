# Xs and Os — live cue player

A SuperCollider live-performance tool for the composition *Xs and Os* (Splice 2026).
It plays MIDI "cues" back under a hand-authored tempo envelope (ignoring the tempo
baked into the MIDI), and drives a tic-tac-toe visualization board.

## Run

1. Install the `wslib` quark once: `Quarks.install("wslib");` then recompile the class library.
2. Open `midi_cue_player.scd`, put the cursor in the `SETUP` block at the bottom, and
   evaluate it (Ctrl+Enter). It boots the server and loads everything.
3. Drive cues with the one-liners at the top of the file:
   - `~play.(id)` — play a cue by name or 1-based number
   - `~next.()` — play the next cue (advances; tapping again mid-cue skips to the next)
   - `~stop.()` — fade out, staying on the current cue
   - `~tempoGui.()` — open the tempo/parameter curve editor
   - `~boardGui.()` — open the Xs-and-Os board (`f` = fullscreen, Esc = exit)

## Layout

- `midi_cue_player.scd` — the performer entry point (the only file you touch live)
- `lib/` — engine, tempo-curve GUI, and visualization board
- `data/` — cue sheet, tempo curves, track map, MIDI bindings (plain text)
- `midi/` — the `.mid` source files
- `plan/` — spec / TODO docs

See `CLAUDE.md` for the full architecture and design notes.
