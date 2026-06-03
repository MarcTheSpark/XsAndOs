# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A SuperCollider live-performance tool for the composition *Xs and Os* (Splice 2026). It loads MIDI "cues" and plays them back through a stand-in synth under a **hand-authored tempo envelope**, deliberately ignoring the tempo information baked into the MIDI files.

Files, split for a **minimal performer interface**:
- **`midi_cue_player.scd`** — the performer entry point. A SETUP block (run once) and a few documented one-liners: `~play.(n)`, `~next.()`, `~stop.()`, `~tempoGui.()`, list `~cues`. This is the only file a performer touches.
- **`cuePlayerEngine.scd`** — the "library": SynthDef, state, and all `~` functions. Loaded once by the SETUP block via `this.executeFile("cuePlayerEngine.scd".resolveRelative)`. **It must stay a single compilation unit** (one wrapping `( … )`), because `executeFile` interprets the whole file at once — splitting it into multiple top-level `( … )` regions like the old version would be a syntax error.
- **`tempoEnvGui.scd`** — the tempo-curve editor (built on core `EnvelopeView`). Also a single compilation unit, also `executeFile`'d by SETUP. Defines `~openTempoEnvGui` / `~tempoGui`.
- **Config files** (plain text, same family): **`Cues/cues.txt`** the cue sheet (carving named beat-windows out of the `.mid` files in `Cues/`), **`tempos.txt`** the saved tempo curves, **`tracks.txt`** the track→synth/role map (global to the piece), **`midi_map.txt`** the saved MIDI bindings. All are created/edited by their respective save functions or by hand and auto-loaded by SETUP if present.

## Running

There is no build or test step — this is SuperCollider code evaluated interactively in the IDE (`scide`) or via `sclang`.

- **Dependency:** the `wslib` quark must be installed once: `Quarks.install("wslib");` then recompile the class library. `SimpleMIDIFile` (used to read MIDI) comes from wslib.
- **Boot + evaluate:** open `midi_cue_player.scd`, place the cursor in the `SETUP` block (the `( s.waitForBoot({ … }) )` at the bottom) and evaluate it once with Ctrl+Enter. It boots the server, loads the engine, sets the tempo envelopes, and loads the cue sheet. Then trigger cues with the one-liners at the top of the file.
- **Performer commands** (after SETUP): `~play.(id)` takes a cue **name** (`"1"`, `"big finish"`, …) or, failing a name match, a raw index; `~next.()` plays the cue at the cursor and advances; `~stop.()` fades out the current cue, or — **if already stopped** — rewinds the cursor one cue without playing (so the next `~next` replays it).
- **MIDI learn** (after SETUP, which calls `~setupMIDI`): `~learnMIDINext.()` / `~learnMIDIStop.()` / `~learnMIDICue.(name)` arm a learn; the next incoming note-on/CC (value > 0) is bound to that action. Pass a path or `true` (e.g. `~learnMIDIStop.(true)`) to persist the whole map to the config file. `~learnMIDICancel.()` aborts.
- **Tempo GUI** (`~tempoGui.()`): opens the curve editor — pick a cue, drag breakpoints (x = beats, y = BPM), set a curve type per segment (named shape **or** a numeric curvature via the "or #:" box — 0 is straight, ± bends the segment), add/remove nodes, **audition** (plays the cue), **save all** (writes `tempos.txt`). Edits write straight into `~tempoEnvs[cueName]`, so `~play`/`~next` use them immediately; saving makes them persist.
- **Quick syntax/compile check without a server:** `sclang` one-liner — `thisProcess.interpreter.compile(File.readAllString("cuePlayerEngine.scd".standardizePath)).notNil` returns `true` if the engine still compiles as one unit (catches the multi-region-block mistake).

## Architecture (one mental model to hold)

The core idea, and the reason the code is more than a MIDI player: **note times are kept in beats and never touched by the MIDI file's tempo map; tempo is re-imposed afterward from a `BPM-over-beats` envelope you write.** A second idea layers on top: **a cue can be a beat-window of a file, re-zeroed to its own beat 0**, so one MIDI file yields many cues.

**Windowing rule** (in `~readCueNotes`): a window is the half-open interval `[startBeat, endBeat)`. A note is kept only if its **onset** is inside the window — notes that started before `startBeat` are dropped (you don't hear a mid-note attack), notes whose onset is inside but that ring past `endBeat` are **truncated** to `endBeat`, and every kept note is shifted so the window's `startBeat` becomes beat 0.

The data flow, all via `~`-prefixed environment-variable functions defined in `cuePlayerEngine.scd`:

1. **Loading** — both loaders fill `~cues` and route note extraction through **`~readCueNotes.(path, startBeat, endBeat)`**, which reads a file with `SimpleMIDIFile` in default `\ticks` mode (beat = `ticks / division`, tempo discarded) and applies the window (see below). Two front doors:
   - **`~loadCues.(dir)`** — every `.mid`/`.midi` in `dir`, lexicographic sort, one whole-file cue each (`endBeat = inf`).
   - **`~loadCueSheet.(cuesTxtPath)`** — reads `cues.txt`, one cue per line `filename start_beat end_beat [optional name]`. `#` comments and blank lines ignored; filenames resolve relative to the sheet's directory and must not contain spaces. This is the primary way to make several cues from one MIDI file.

   Each cue is `(name:, file:, path:, startBeat:, endBeat:, notes:)`.

2. **`~tempoEnvs[key]`** — a `Dictionary` of `key` → an `Env` of **BPM over (window-relative) beats**. Lookup is via **`~tempoEnvFor.(cue)`**, which tries the cue's `name` first (specific window, e.g. `"tesCue.mid [10-20]"` or a custom 4th-column label), then the bare `file` basename (covers every window of that file), then `~defaultTempoEnv` (constant 120).

3. **`~buildTimeMap` / `~beatToTime`** — convert beats → seconds. `period(beat) = 60/BPM(beat)`; `time(beat)` is the cumulative-trapezoid integral of that period over a dense beat grid (`resolution = 0.01` beat). This integration is **agnostic to the Env's curve types** — whatever BPM shape you draw is rendered exactly. Querying past the envelope's duration clamps to (holds) the final BPM.

4. **`~playCue.(index)`** — the primitive. Picks the cue's tempo env, maps every note's start/end beat through `~beatToTime`, resolves each note's **track → role/target** via `~trackRoleFor` (which SynthDef to play, or `\visual board`), sorts by absolute seconds, then plays them from a `Routine` on **`SystemClock` in absolute seconds** (no `TempoClock` — tempo is already baked in). `\audio` notes spawn their track's SynthDef; `\visual` notes are scheduled but currently no-op (the F2 board hook). Each cue gets its own `Group`. Interrupts whatever is playing first.

5. **Cursor model** — `~cueIndex` is a **cursor pointing at the cue `~next` will play next** (starts at 0). `~playCue.(i)` plays cue `i` then sets the cursor to `(i + 1)` clamped at the last cue, so playback is *play-then-advance*; this is the single place the cursor moves forward (so a direct `~play.(id)` also advances it). `~stopCue` is the **internal primitive**: `\gate -> 0` on the group (fast fade via `killEnv`) then reaps it. `~playCue`'s Routine also clears `~playing` and reaps the group on **natural completion** — so the system can tell "playing" from "finished/stopped" (what the two-mode `~stop` relies on).

6. **Performer wrappers** (bottom of the engine, the only names the Main file documents) — `~play` resolves a cue name to an index (`~cues.detectIndex` on `name`, else uses the arg as a raw index) then calls `~playCue`; `~next` plays the cursor (`~playNext` → `~playCue.(~cueIndex)`); `~stop` is **two-mode**: if `~playing.notNil` it fades out via `~stopCue`, otherwise (already stopped) it just rewinds the cursor `~cueIndex - 1` **without playing**, so a later `~next` replays the earlier cue. Everything else is internal.

### MIDI

`~setupMIDI` calls `MIDIClient.init` + `MIDIIn.connectAll` and installs two responders (`MIDIdef.noteOn`/`MIDIdef.cc`) that funnel every value-> 0 message into `~onMidi.(type, chan, num, val)`. `~onMidi` has two modes: if a learn is armed (`~midiLearning`), it records `"type chan num" -> action` into `~midiMap` (optionally saving); otherwise it looks the key up and calls `~fireAction`, which dispatches `\next`/`\stop`/cue-name. Bindings persist as a plain text file (`type chan num action`, e.g. `note 0 60 next`) via `~saveMidiMap`/`~loadMidiMap`; `~actionFromToken` maps `"next"`/`"stop"` back to symbols and treats anything else as a cue name. The default config path is `~midiMapPath`, set by SETUP to `midi_map.txt` next to the `.scd`; `~setupMIDI` auto-loads it if present.

### Tempo GUI & persistence

`tempoEnvGui.scd` edits the *same* `~tempoEnvs` dictionary the engine plays from. The bridge is two converters: **`~tgEnvToModel`** turns an `Env` into a `(beats:, bpms:, curves:)` model (absolute beats starting at 0, one curve per segment) and **`~tgModelToEnv`** turns it back (`Env(bpms, beatDurations, curves)`, BPM clamped ≥ 1). The editor uses a core **`EnvelopeView`**, which works in **normalized 0–1** on both axes and has *no* Env conversion of its own — so `refresh` maps model→view (`beat / maxBeat`, `(bpm - minBPM)/(maxBPM - minBPM)`) and the `action` callback (`readView`) maps view→model and writes `~tempoEnvs[name] = ~tgModelToEnv.(model)` on every drag. Hence changes are audible via `~play` immediately; **save all** is what persists them. Persistence is `~saveTempoEnvs`/`~loadTempoEnvs` with the line format `name | bpm levels | beat durations | curves` (the name is everything before the first `|`, so bracketed window names survive); `~parseCurve` reads a curve token as a numeric curvature if it's all `[0-9.eE+-]`, else a shape symbol. Default path `~tempoEnvPath` = `tempos.txt`, set and auto-loaded by SETUP (it overrides the inline `~tempoEnvs[...] = Env(...)` starting points).

The synths are a small library — `\sawCue`, `\pulseCue`, `\sineCue`, `\triCue` — all sharing one arg contract (`out/freq/amp/dur/atk/rel/gate`) so any track can route to any of them. Each has two envelopes: `ampEnv` (gives the note its computed duration, self-frees) and `killEnv` (a sustained gate that `~stopCue` drops to fade out cleanly without a click). They are stand-in timbres (distinct waveforms), with headroom for per-cue param controls (F3).

### Tracks

`~readCueNotes` keeps each note's source `track:` index. `tracks.txt` maps `track role target` (role `audio` → a SynthDef name; role `visual` → `board`), loaded by SETUP via `~loadTrackMap` into `~trackRoles`; the mapping is **global to the piece**, not per-cue. `~trackRoleFor.(track)` looks a track up, defaulting unlisted tracks to `(role: \audio, target: ~defaultTrackTarget)` (`\sawCue`). A cue plays all its tracks simultaneously on its single tempo timeline, each track on its own voice.

## Conventions / gotchas specific to this code

- **Curve semantics matter and are intentional.** In a BPM envelope, `\lin` is *not* a linear-in-period accel and `\exp` is geometric-in-BPM. Use `\exp` for a smooth musical accelerando. The engine renders any curve faithfully, so the choice is purely musical.
- **Tempo envelopes are keyed by cue name (or file basename as fallback).** For a window the name is `"<file> [<start>-<end>]"` using the *text as written in `cues.txt`* (so `0 10` → `"tesCue.mid [0-10]"`, not `[0.0-10.0]`), or the 4th-column label if you gave one. The number list is BPM values; the durations list is in **window-relative beats**.
- A tempo env shorter than the cue is fine — it sustains its last BPM. A cue with no entry plays at a flat 120.
- Paths use SuperCollider idioms: `"Cues".resolveRelative` (relative to the `.scd` file), `.standardizePath`, `.pathMatch`.
