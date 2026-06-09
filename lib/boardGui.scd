// ============================================================================
// boardGui.scd  --  the Xs and Os tic-tac-toe visualization board (F2).
//
// Loaded once by midi_cue_player.scd (this.executeFile ...). Open with
//   ~boardGui.value
// A cue's "visual" track (tracks.txt: `<n> visual board`) feeds note pitches to
// ~boardEvent while it plays; the engine schedules those notes on the SAME
// beat->time map as the audio, so the board stays locked to the tempo-warped
// performance. ~boardEvent defers all GUI work to AppClock (the cue routine runs
// on SystemClock).
//
// Pitch -> board:
//   60..68  = Player 1 (X), square = pitch - 60   (0..8, row-major)
//   72..80  = Player 2 (O), square = pitch - 72
//   48      = clear the board -- fades the marks out over the note's length (its
//             tempo-warped duration in seconds), then resets the state
//   velocity 127 marks a WINNING-line cell -> coloured turquoise (P1) / maroon (P2)
//   the newest move is shown bold
//
// State lives here (~boardState etc.) so it survives between cues; we rely on the
// 48-clear note to reset, so a window that starts mid-game keeps prior state.
//
// Must stay ONE compilation unit (it is executeFile'd as a whole).
// ============================================================================
(
~boardDebug      = false;                  // set true to print [debug] lines on play (track roles, visual notes)
~boardP1Base     = 60;
~boardP2Base     = 72;
~boardClearPitch = 48;

// state: 9 cells, each (player: 0|1|2, win: bool); player 0 == empty.
~boardState  = Array.fill(9, { (player: 0, win: false) });
~boardNewest = nil;                       // index of the most recent move (drawn bold)
~boardWin    = nil;                        // the Window, or nil if never opened
~boardCells  = nil;                        // 9 StaticTexts, row-major, or nil
~boardFade   = 1.0;                        // mark opacity 0..1 (a clear-board note fades this 1->0)
~boardFadeRoutine = nil;                   // the running fade-out Routine, or nil

~boardColors = (
	mark:  Color.white,                    // a normal X / O
	p1win: Color(0.20, 0.80, 0.78),        // turquoise -- Player 1 winning cell
	p2win: Color(0.60, 0.10, 0.20),        // maroon    -- Player 2 winning cell
	empty: Color.gray(0.35),
	cell:  Color.gray(0.16),
	bg:    Color.gray(0.10)
);

~boardClear = {
	~boardState  = Array.fill(9, { (player: 0, win: false) });
	~boardNewest = nil;
};

// Apply one pitch to the state (no GUI). vel 127 => winning cell.
~boardApply = { |pitch, vel = 127|
	if(pitch == ~boardClearPitch) {
		~boardClear.value;
		if(~boardDebug == true) { "  [debug] board: pitch 48 -> CLEAR".postln };
	} {
		var player = nil, sq = nil;
		if((pitch >= ~boardP1Base) and: { pitch <= (~boardP1Base + 8) }) {
			player = 1; sq = pitch - ~boardP1Base;
		};
		if((pitch >= ~boardP2Base) and: { pitch <= (~boardP2Base + 8) }) {
			player = 2; sq = pitch - ~boardP2Base;
		};
		player.notNil.if {
			~boardState[sq] = (player: player, win: (vel >= 127));
			~boardNewest = sq;
			if(~boardDebug == true) {
				"  [debug] board: pitch % -> P% square % %".format(
					pitch, player, sq, if(vel >= 127) { "(WIN)" } { "" }).postln;
			};
		} {
			if(~boardDebug == true) {
				"  [debug] board: pitch % is outside P1(60-68)/P2(72-80)/clear(48) -- ignored".format(pitch).postln;
			};
		};
	};
};

// Redraw all cells from state. Safe to call with no window open (no-op).
~boardDraw = {
	~boardCells.notNil.if {
		~boardState.do({ |cell, i|
			var t    = ~boardCells[i];
			var bold = (i == ~boardNewest);
			var mark = switch(cell[\player], 1, { "X" }, 2, { "O" }, { "" });
			var col  = switch(cell[\player],
				1, { if(cell[\win]) { ~boardColors[\p1win] } { ~boardColors[\mark] } },
				2, { if(cell[\win]) { ~boardColors[\p2win] } { ~boardColors[\mark] } },
				{ ~boardColors[\empty] });
			col = Color(col.red, col.green, col.blue, col.alpha * ~boardFade);   // apply fade
			t.string_(mark);
			t.font_(Font("Helvetica", 56, bold: bold));
			t.stringColor_(col);
		});
	};
};

// Fade the marks out over `dur` seconds (~30 fps on AppClock), then clear the
// state and snap opacity back to full. Cancels any fade already in flight. A
// non-positive dur clears instantly. Must be called on AppClock (~boardEvent is).
~boardFadeOut = { |dur = 0|
	~boardFadeRoutine.stop;                       // cancel a fade already running
	if(dur > 0.05) {
		var steps = (dur * 30).max(1).round.asInteger;
		var dt    = dur / steps;
		~boardFadeRoutine = Routine({
			steps.do({ |k|
				~boardFade = 1.0 - ((k + 1) / steps);
				~boardDraw.value;
				dt.wait;
			});
			~boardClear.value;                    // marks faded out -> reset state
			~boardFade = 1.0;
			~boardFadeRoutine = nil;              // fade done (so "is a fade running?" reads false)
			~boardDraw.value;
		}).play(AppClock);
	} {
		~boardClear.value;
		~boardFade = 1.0;
		~boardFadeRoutine = nil;
		~boardDraw.value;
	};
	if(~boardDebug == true) { "  [debug] board: pitch 48 -> CLEAR (fade %.2f s)".format(dur).postln };
};

// Public entry called by the engine for each visual note. Wrapped in .defer so
// the SystemClock cue routine never touches the GUI directly. Safe with no window.
// `dur` is the note's tempo-warped length in seconds; only the clear note uses it.
~boardEvent = { |pitch, vel = 127, dur = 0|
	{
		if((~boardDebug == true) and: { ~boardCells.isNil }) {
			"  [debug] board: ~boardEvent called but no window open (run ~boardGui.()).".postln;
		};
		if(pitch == ~boardClearPitch) {
			~boardFadeOut.(dur);                  // clear board -> fade out over the note length
		} {
			~boardFadeRoutine.notNil.if {         // a clear was mid-fade: finish it first so the
				~boardFadeRoutine.stop;            // new move lands on a freshly cleared board
				~boardClear.value;
				~boardFadeRoutine = nil;
			};
			~boardFade = 1.0;                     // a move is always drawn fully opaque
			~boardApply.(pitch, vel);
			~boardDraw.value;
		};
	}.defer;
};

// Open (or reopen) the 3x3 board window and hold a reference for live updates.
~boardGui = {
	var grid;
	~boardWin.notNil.if { ~boardWin.close };
	~boardCells = Array.fill(9, {
		StaticText().align_(\center).background_(~boardColors[\cell]).string_("")
	});
	grid = GridLayout.new.spacing_(4).margins_(8);
	3.do({ |r| 3.do({ |c| grid.add(~boardCells[(r * 3) + c], r, c) }) });
	~boardWin = Window("Xs and Os", Rect(320, 200, 360, 360)).background_(~boardColors[\bg]);
	~boardWin.layout_(grid);
	~boardWin.front;
	~boardDraw.value;
	~boardWin;
};

"board GUI loaded.".postln;
)
