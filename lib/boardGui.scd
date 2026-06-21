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
//             tempo-warped duration in seconds), then resets the state. EXCEPTION:
//             a clear chorded with a draw note (same onset) clears INSTANTLY so the
//             new move lands on a fresh board (the engine passes dur 0; see ~playCue).
//   49      = fade the GRID lines OUT over dur (the crisscross disappears)
//   47      = fade the GRID lines IN over dur (the crisscross appears)
//             (49/47 drive ~boardGridFade and touch only the grid lines, not the
//              marks or background. The grid STARTS fully faded out.)
//   velocity 127 marks a WINNING-line cell -> drawn thick + coloured (X vibrant red,
//             O vibrant green); the newest move is also drawn thick
//
// State lives here (~boardState etc.) so it survives between cues; we rely on the
// 48-clear note to reset, so a window that starts mid-game keeps prior state.
//
// Must stay ONE compilation unit (it is executeFile'd as a whole).
// ============================================================================
(
~boardDebug      = false;                  // set true to print [debug] lines on play (track roles, visual notes)
~boardP1Base       = 60;
~boardP2Base       = 72;
~boardClearPitch   = 48;
~boardFadeOutPitch = 49;                   // fade the GRID out (lines disappear)
~boardFadeInPitch  = 47;                   // fade the GRID in (lines appear)

// state: 9 cells, each (player: 0|1|2, win: bool); player 0 == empty.
~boardState  = Array.fill(9, { (player: 0, win: false) });
~boardNewest = nil;                       // index of the most recent move (drawn bold)
~boardWin    = nil;                        // the Window, or nil if never opened
~boardView   = nil;                        // the UserView we draw the board onto, or nil
~boardSize   = 800@800;                     // fixed board size (a Point), drawn centered in the window
~boardFullScreen = false;                  // true while the window is in fullscreen (Escape exits)
~boardFade   = 1.0;                        // mark opacity 0..1 (a clear-board note fades this 1->0)
~boardFadeRoutine = nil;                   // the running mark fade-out Routine, or nil
~boardGridFade = 0.0;                       // grid-line opacity 0..1 (starts hidden; 47 fades in, 49 fades out)
~boardGridFadeRoutine = nil;               // the running grid fade Routine, or nil

~boardColors = (
	mark:  Color.white,
	p1win: Color(1.0, 0.13, 0.13),             // X win -- vibrant red
	p2win: Color(0.10, 0.90, 0.25),            // O win -- vibrant green
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

// Pen renderer (the UserView's drawFunc body). Fills the whole view with the black
// ground, then draws a real tic-tac-toe board at the FIXED size ~boardSize, CENTERED
// in the view (so the board stays the same size however big the window is): the white
// crisscross grid (two verticals + two horizontals, no outer box) and an X/O stroked
// per occupied cell. The grid's opacity is ~boardGridFade (47/49 fade it in/out; starts
// hidden); marks honor ~boardFade (the clear fade). Called on the GUI thread by the view.
~boardRender = { |bounds|
	var bw = ~boardSize.x, bh = ~boardSize.y;        // fixed board size
	var bx = (bounds.width  - bw) / 2;               // centered origin within the view
	var by = (bounds.height - bh) / 2;
	var m  = bw.min(bh) * 0.08;                      // inner margin of the board
	var x0 = bx + m, y0 = by + m, x1 = bx + bw - m, y1 = by + bh - m;
	var cw = (x1 - x0) / 3, ch = (y1 - y0) / 3;
	var lineW = (bw.min(bh) * 0.014).max(2);         // grid line thickness
	var fade  = ~boardFade;

	Pen.fillColor = ~boardColors[\bg];
	Pen.fillRect(bounds);

	// crisscross grid lines (white), faded in/out via ~boardGridFade
	if(~boardGridFade > 0) {
		Pen.strokeColor = Color.white.alpha_(~boardGridFade);
		Pen.width = lineW;
		Pen.moveTo((x0 + cw)        @ y0); Pen.lineTo((x0 + cw)        @ y1);
		Pen.moveTo((x0 + (cw * 2))  @ y0); Pen.lineTo((x0 + (cw * 2))  @ y1);
		Pen.moveTo(x0 @ (y0 + ch));        Pen.lineTo(x1 @ (y0 + ch));
		Pen.moveTo(x0 @ (y0 + (ch * 2)));  Pen.lineTo(x1 @ (y0 + (ch * 2)));
		Pen.stroke;
	};

	// X / O marks (full colour; only the clear fade affects them)
	~boardState.do({ |cell, i|
		var player = cell[\player];
		if(player > 0) {
			var row  = i div: 3, col = i mod: 3;
			var ins  = cw.min(ch) * 0.24;
			var r    = Rect(x0 + (col * cw), y0 + (row * ch), cw, ch).insetBy(ins, ins);
			var base = switch(player,
				1, { if(cell[\win]) { ~boardColors[\p1win] } { ~boardColors[\mark] } },
				2, { if(cell[\win]) { ~boardColors[\p2win] } { ~boardColors[\mark] } });
			Pen.strokeColor = Color(base.red, base.green, base.blue, base.alpha * fade);
			// thick when it's the newest move OR a winning (vel >= 127) cell
			Pen.width = if((i == ~boardNewest) or: { cell[\win] }) { lineW * 2 } { lineW * 1.2 };
			if(player == 1) {                       // X: two diagonals
				Pen.moveTo(r.left @ r.top);    Pen.lineTo(r.right @ r.bottom);
				Pen.moveTo(r.left @ r.bottom); Pen.lineTo(r.right @ r.top);
				Pen.stroke;
			} {                                     // O: a circle
				Pen.strokeOval(r);
			};
		};
	});
};

// Request a redraw. Safe to call with no window open (no-op). The actual drawing
// happens in ~boardRender via the view's drawFunc; this just triggers it.
~boardDraw = {
	~boardView !? { ~boardView.refresh };
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

// Fade the GRID lines' opacity from its current value to `to` (0=hidden, 1=full) over
// `dur` seconds (~30 fps on AppClock), then hold at `to`. Cancels any grid fade in
// flight. A non-positive dur snaps instantly. Touches only the grid (~boardGridFade),
// not the marks or background. Must run on AppClock.
~boardFadeGrid = { |to = 1, dur = 0|
	var from = ~boardGridFade;
	~boardGridFadeRoutine.stop;                   // cancel a grid fade already running
	if(dur > 0.05) {
		var steps = (dur * 30).max(1).round.asInteger;
		var dt    = dur / steps;
		~boardGridFadeRoutine = Routine({
			steps.do({ |k|
				~boardGridFade = from + ((to - from) * ((k + 1) / steps));
				~boardDraw.value;
				dt.wait;
			});
			~boardGridFade = to;
			~boardGridFadeRoutine = nil;
			~boardDraw.value;
		}).play(AppClock);
	} {
		~boardGridFade = to;
		~boardGridFadeRoutine = nil;
		~boardDraw.value;
	};
	if(~boardDebug == true) { "  [debug] board: grid fade % -> % (%.2f s)".format(from, to, dur).postln };
};

// Public entry called by the engine for each visual note. Wrapped in .defer so
// the SystemClock cue routine never touches the GUI directly. Safe with no window.
// `dur` is the note's tempo-warped length in seconds; only the clear note uses it,
// as the fade-out time -- the engine passes dur 0 for a clear chorded with a draw,
// so that clear is instant and the chorded move lands on a fresh board.
~boardEvent = { |pitch, vel = 127, dur = 0|
	{
		if((~boardDebug == true) and: { ~boardView.isNil }) {
			"  [debug] board: ~boardEvent called but no window open (run ~boardGui.()).".postln;
		};
		switch(pitch,
			~boardClearPitch,   { ~boardFadeOut.(dur) },        // clear -> fade marks out over the note length
			~boardFadeOutPitch, { ~boardFadeGrid.(0, dur) },    // 49 -> fade the grid out
			~boardFadeInPitch,  { ~boardFadeGrid.(1, dur) },    // 47 -> fade the grid in
			{                                                   // default: a player move
				~boardFadeRoutine.notNil.if {     // a clear was mid-fade: finish it first so the
					~boardFadeRoutine.stop;        // new move lands on a freshly cleared board
					~boardClear.value;
					~boardFadeRoutine = nil;
				};
				~boardFade = 1.0;                 // a move is always drawn fully opaque
				~boardApply.(pitch, vel);
				~boardDraw.value;
			}
		);
	}.defer;
};

// Open (or reopen) the board window. `dimensions` (a Point, e.g. 500@500) is the FIXED
// board size, drawn centered in the window by ~boardRender no matter how big the window
// is. `fullScreen` opens the window covering the whole screen (the board stays its fixed
// size, centered). A single UserView fills the window; the black ground fills the rest.
// 'f' enters fullscreen; Escape exits fullscreen (back to a normal window) or, when
// already windowed, closes it.
//   ~boardGui.()            -- default 800@800, windowed
//   ~boardGui.(700@700)     -- different board size, windowed
//   ~boardGui.(800@800, true) -- fullscreen (Escape to exit)
~boardGui = { |dimensions, fullScreen = false|
	~boardSize = dimensions ? (800@800);
	~boardWin.notNil.if { ~boardWin.close };
	~boardView = UserView().background_(Color.black).canFocus_(true);
	~boardView.drawFunc = { |v| ~boardRender.(v.bounds) };
	// Keys: 'f' enters fullscreen; Escape leaves fullscreen if we're in it, else closes.
	~boardView.keyDownAction = { |view, char, mods, unicode, keycode, key|
		case
		{ char == $f } {
			if(~boardFullScreen != true) { ~boardWin.fullScreen; ~boardFullScreen = true };
		}
		{ unicode == 27 } {
			if(~boardFullScreen == true) { ~boardWin.endFullScreen; ~boardFullScreen = false; ~boardWin.front }
			{ ~boardWin.close };
		}
		{ key == 32 } {
			~next.();
		};
	};
	~boardWin = Window("Xs and Os", Rect(320, 200, ~boardSize.x + 80, ~boardSize.y + 80))
		.background_(Color.black);
	~boardWin.layout_(VLayout(~boardView).margins_(0).spacing_(0));
	~boardFullScreen = fullScreen;
	if(fullScreen) { ~boardWin.fullScreen } { ~boardWin.front };
	~boardView.focus(true);                       // so it receives the Escape key
	~boardDraw.value;
	~boardWin;
};

"board GUI loaded.".postln;
)
