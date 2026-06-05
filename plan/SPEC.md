# Roadmap spec — Xs and Os cue player

Planned additions beyond the current state (single-voice MIDI cue player with a
hand-drawn tempo curve). Read `CLAUDE.md` first for how the existing system works;
this file only describes what's being *added* and the decisions already locked.

Decisions recorded 2026-06-03. Build order: **F4 → F1 → F2 → F3.**

## Unifying idea

The architecture already keeps everything in **beats** and re-imposes a hand-drawn
**curve over beats** (today: BPM). The roadmap generalizes that:
- Tempo becomes just one parameter curve (`\tempo`), privileged only because it
  defines the beat→time warp. Every other curve is sampled on top of that warp.
- A cue stays "a beat-window of one MIDI file." We stop collapsing its tracks into
  one voice; each track gets its own synth (or the board).

A cue can have **multiple tracks sounding at once** — it already does (all tracks
are flattened into one note list today); F1 just stops collapsing them to one voice.
All tracks in a cue share the cue's single tempo curve / timeline.

---

## Phase 0 — groundwork (do alongside F4)

Add a `track:` field to the note model now. `~readCueNotes`
(`cuePlayerEngine.scd:73`) currently discards the track index `e[0]`; keep it:
`(startBeat:, durBeats:, midinote:, vel:, track:)`. Harmless to everything else;
saves re-touching the loader in F1/F2.

## Phase 1 — F4: numeric curve shapes *(smallest, first)*

Engine + persistence already handle numeric curvature end-to-end (`~parseCurve`,
`Env`, `~saveTempoEnvs`). **GUI-only work** in `tempoEnvGui.scd`:
- Add a curvature `NumberBox` beside the curve `PopUpMenu`; add a "(number)" menu
  item that enables the box.
- On change, write the number into `model[\curves][seg]` and `refresh`
  (`EnvelopeView.curves_` accepts numbers).
- **Done when:** set a segment curvature like `-4`, audition, save, reload, and the
  shape survives.

## Phase 2 — F1: multi-track audio, each track → its own synth

- **`tracks.txt`** — new **global per-piece** config (NOT per-cue). Lines:
  `track role target`, e.g. `0 audio sawCue`, `1 audio bassCue`, `2 visual board`.
  New `~loadTrackMap` / `~trackRoles`, auto-loaded by SETUP. Unlisted tracks default
  to `audio sawCue`.
- **SynthDef library** — 2–3 SynthDefs sharing one arg contract
  (`out, freq, amp, dur, atk, rel, gate` + room for F3 params). `\sawCue` is the template.
- **`~playCue`** — group notes by track; audio tracks spawn their synth, visual
  tracks are skipped here (handled in F2). Still one `Group` per cue.
- **Check when starting:** does `tesCue.mid` have a meta/tempo track 0 with no
  notes? Inspect before assuming track indices.

## Phase 3 — F2: visualization track (tic-tac-toe board)

- **`boardGui.scd`** — new file, `executeFile`'d by SETUP like the tempo GUI. A 3×3
  grid window, opened with `~boardGui.()`, holding a reference so playback updates it
  live.
- **`~boardEvent.(pitch, vel)`** — pitch → `(player, square)`:
  - Player 1 = pitches **60–68**, Player 2 = pitches **72–80**; `square = pitch - base`
    (0–8).
  - Pitch **48** = clear the board.
  - Velocity **127** = winning-line cell, colored: **turquoise** (P1) / **maroon** (P2).
  - Newest move shown **bold**.
- **Sync** — the visual track's notes are scheduled in the *same* `~playCue` routine
  on the *same* beat→time map, so they stay locked to the tempo-warped audio. The
  routine runs on SystemClock, so `~boardEvent` GUI updates must be wrapped in `.defer`
  (AppClock).
- **To settle when starting:** board reset between cues, or rely on the 48-clear note
  so windows mid-game keep state? (Leaning: rely on 48-clear.)

## Phase 4 — F3: per-(cue, track, param) parameter curves *(hybrid)*

- **Keying — `(cue, track, param)`.** Param curves are keyed by cue **and track**
  (not just cue), so e.g. a cutoff sweep can apply to the bass track only and not the
  lead. Tempo is the exception: `\tempo` is per-cue (one timeline for the whole cue),
  so it is effectively keyed `(cue, \tempo)` / track-agnostic.
  - Storage shape: `~paramEnvs[cueName][trackOrTempoKey][param] → Env over beats`,
    or a flat dict keyed by a composite string — pick whichever is cleaner at
    implementation, but the *addressable identity is `(cue, track, param)`*.
- **Hybrid control model:**
  - *Now (onset sampling):* in `~playCue`, for each note sample every param curve
    defined for that note's `(cue, track)` at the note's start beat and append
    `\param, value` to the `Synth` args. Synths silently ignore unknown control
    names, so coupling stays loose.
  - *Later (continuous):* keep curves keyed only by `(cue, track, param)` with no
    deeper synth coupling, so a future control-bus mode (`In.kr` glide during held
    notes) can map the same curves onto buses without re-authoring them.
- **Persistence** — extend the tempo line format to:
  `name | track | param | levels | durations | curves`.
  Missing `param` ⇒ `tempo`; missing `track` ⇒ tempo/all-tracks. This must still read
  the existing `tempos.txt` (which has no track/param columns) as tempo curves.
- **Editor** — the tempo GUI becomes the generic curve editor: add a **track**
  selector and a **parameter** selector beside the cue menu. Selecting a param swaps
  the y-axis label/range (tempo unchanged). Each `(cue, track, param)` is one editable
  curve.

---

## Open questions deferred to implementation time

1. `tesCue.mid` track layout (meta track 0?).
2. Board reset-per-cue vs. 48-clear-only.
3. Exact synth library + which params each synth exposes (drives the F3 param list).
4. Whether `\tempo` should also be allowed per-track later (currently no — one
   timeline per cue).
