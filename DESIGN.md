# amber — design

## What it is for

1. **A circuit simulator a beginner can learn from**: a schematic on screen, the voltages on it, and
   meters that can be put anywhere.
2. **A library benchtop can run beside its emulated microcontrollers**, so that a GPIO pin drives an
   LED through a resistor and an ADC reads a real divider. Guest time is the master clock: the analog
   solver advances in chunks between synchronisations; a GPIO output is a source with an output
   resistance, PWM is a source changing at timed edges, an ADC input reads a node, a GPIO input
   thresholds one. Hence an **incremental API** — set a source, advance to a time, read a node — rather
   than "run a whole analysis and return a table".
3. **A stressor for sysl**: sparse LU with pivoting and a reused symbolic factorisation, Newton–Raphson
   whose failures are `Result` paths, complex arithmetic for AC, and device evaluation in a hot loop.

## Shape

- `sh.sysl.amber` — the library. `Circuit` (named nodes, parts), `Sim` (the solver), `Schematic` (the
  grid file format, which builds a `Circuit`), value parsing in SPICE's notation. No OS, no SDL.
- `cli/` — `amber-cli`, which runs a SPICE netlist and prints its tables.
- `oracle/` — netlists and the script that runs them through ngspice into `tests_oracle.sysl`.
- `app/` — the viewer, a workspace member, on syslui-sdl. The schematic's lines are drawn into a
  PlutoVG surface handed to the canvas as an image, since syslui's canvas is rectangles and text by
  design.

## The solver

Modified nodal analysis: one KCL equation per non-ground node, plus a current unknown per voltage
source and per inductor, plus an inner node per diode with series resistance. Coupled inductors (a
transformer) add their mutual inductance between their two current equations. Nonlinear parts are
linearised about the present solution and the system re-solved until no node voltage moves (relative
1e-6, absolute 1e-9, or within 1e-7 of the largest node voltage, which is rounding) and every
junction lies where it was linearised — by its voltage, or for a diode by its current, as SPICE
judges one, so a reversed diode on a weakly held node is not chased through its voltage's rounding.
Branch currents are not judged: once the junctions and node voltages hold, they follow linearly.
Junction steps are limited as SPICE's `pnjlim` does. If plain Newton fails, gmin stepping: a shunt
from every node to ground, removed a decade at a time.

A step's error is judged on every node voltage and inductor current, never finer than that rounding,
and never on a voltage source's current, which is algebraic and mostly rounding once steps are short.

A diode's reported current is read off the line the last system was linearised on, so KCL holds
exactly at every node in what is reported.

A part has two terminals (`a`, `b`) or three (`a`, `b`, `c`; `c` is -1 on a two-terminal part). A
bipolar transistor is SPICE's Gummel–Poon model reduced to its transport and Early terms (IS, BF, BR,
NF, NR, VAF, VAR), NPN or PNP, with GMIN across each junction in the base current as SPICE puts it. Its
two junctions, base–emitter and base–collector, are each limited by `pnjlim` on the bare thermal
voltage, and the collector and base currents are each linearised against both; the emitter carries
both back out. Its terminal currents are read off the linearisation like a diode's.

A MOSFET is SPICE's level 1 (Shichman–Hodges: VTO, KP, LAMBDA, and W and L on the instance), NMOS or
PMOS, with its bulk on its source, so there is no body effect and no bulk diode; a netlist's GAMMA and
PHI, and a bulk node elsewhere, leave notes. Drain and source change places when `vds` is below zero,
as SPICE has it, and GMIN runs from drain to source, where SPICE's drain–bulk junction puts it. Its
drain current is linearised against `vgs` and `vds`, which are limited as SPICE's `fetlim` (against
the threshold, on whichever terminal is the source now) and `limvds` limit them; its gate carries
nothing and its source carries the drain's current back out, read off the linearisation like a
diode's.

## Instruments

**A signal generator is a part of its own, `Generator(wave, ohms)`**, rather than a source and a
resistor with a node between them: what a person clicks, meters and reads the current of is the
instrument, and its terminals are its output and its return. It is stamped as its Norton equivalent —
`wave / ohms` into the output in parallel with `ohms` — so it needs no unknown of its own, and its
current is `(v(out) − v(return) − wave) / ohms`, negative while it delivers, as a battery's is. The
output resistance must be more than zero, 50 Ω unless the line says otherwise.

**A triangle is a pulse with no top** (`triangle()`: rise and fall each half the period, width zero),
and a sawtooth a pulse that is all rise (`sawtooth()`: rise all but a thousandth of the period, fall
that thousandth, as a square's edges are), neither a variant of `Wave`: the solver already lands a step on each of a pulse's corners, a netlist
writes it as `PULSE`, and the generator's parameters live in its `Oscillator`, not in the wave.

**An `Oscillator` holds a generator's settings and its phase.** Every waveform's cycle starts where a
sine's does, at the offset and rising. `retuned(t)` measures the cycle from the moment of a change, so
a new frequency, amplitude or waveform carries on from where the old wave was in its cycle — a bench
generator does not restart its cycle when a knob turns — and `wave()` builds the `Wave` that does
that from `start` on. A change is handed to the solver with `set_wave`, which is a corner: the next
step is a short backward-Euler one with no history, and every capacitor and inductor carries on from
the state it was in.

**The viewer's instrument panel is generic, the instrument is not.** A `Panel` is a title, a list of
`Choice`s (a row of options over a `Signal[int]`) and `Knob`s (a slider over a `Signal[real]`,
logarithmic or straight), drawn beside the scope while its part is selected. Every frame asks each
panel whether a setting moved since it was last applied, and if one did the panel's `Instrument` puts
its part in the circuit from the present time. The bench supply is the second `Instrument` variant,
with its own choices (regulated or raw, 50 or 60 Hz), knobs (voltage, current limit, ripple) and arm
of `apply`; the panel, its drawing and the frame's sync took it as they were.

**A bench supply is a part of its own, `Supply(PowerSupply)`, stamped as the current it delivers
against the voltage across it** — no node or unknown of its own, its operating voltage kept in the
part's junction slot as a diode's is, so its current is read off the line the system balanced. The
current is the smaller of what its open-circuit voltage drives through its resistance and its limit,
`min((e − v) / r, I)`, with the corner rounded by a softplus over a thousandth of `I`: the curve and
its slope (a logistic between `−1/r` and 0) are continuous, falling and concave, so Newton's method
on it cannot circle between the two modes, as it can on a hard corner whose slope jumps; `r` is a
milliohm regulated, so CV holds to microvolts and the rounding moves the corner by microvolts.
`current_limited` is the CC lamp: the CV characteristic would exceed the limit.

**Raw mode is the same curve with a different `e` and `r`**: `e` is a `Pulse` sawtooth at twice the
mains (a fifth of each half cycle charging, the rest discharging — a capacitor-input filter's shape),
averaging the set voltage with the set ripple peak to peak, and `r` the internal resistance, so the
output sags under load. Being a `Pulse`, the solver lands a step on each corner, and a netlist writes
it exactly as `PULSE` and a resistor, which is how the regulator example is held to ngspice. The
ripple does not grow with the load, as a real filter capacitor's would; it is the ripple at the load
the supply is set for.

**A zener is a diode with SPICE's breakdown**: `BV` and `IBV` on `DiodeModel`, a second exponential
`−is · exp(−(v + knee) / (n · Vt))` whose knee SPICE's iteration places so the current at `−BV` is
`IBV`, summed smoothly with the forward one, and junction limiting on that exponential measured back
from the knee when the junction is reversed past it, as ngspice limits it.

## Editing

**The viewer becomes an editor of the file it opened, and the circuit keeps running while it is
edited.** A beginner learns most from changing a value and watching what follows, so an edit reaches
the running circuit as soon as it is made: drop a resistor, and its voltage and current dots are there
a frame later. Saving writes the file back, in the format a person writes by hand.

### Two modes on one board

**`e` switches between running and editing**, because the same click already means something when
running: two grid points make a meter, a switch flips, a generator opens its panel. Running is exactly
as it is now, and looks exactly as it does now. Editing adds a palette of parts on the left and its own
hint line, and gives clicks, drags and keys their editing meanings. The clock keeps running in both, so
the board always shows the circuit as last committed. `amber-app new.amber`, where the file does not
exist, opens an empty board already editing.

### The document is the file's own lines

**An edit changes lines of text, and the text is parsed again; nothing else holds the circuit.** The
library gains a `Document` (`sh/sysl/amber/document.sysl`), which holds the file's lines exactly as read
and records which line each element came from. A transformer is one line making two elements, and
`Element` gains a `line` field to say which. Every operation is a change to lines:

- **Moving, rotating or flipping** rewrites the coordinates on that element's line, leaving its name,
  value, comment and column alignment as they were. A field that gets longer pushes the rest of the
  line right rather than squeezing it.
- **Changing a value or name** rewrites those words alone.
- **A new element** is a new line at the end of the file, written in the examples' layout.
- **Deleting** removes the line. A transformer goes as a whole.
- `speed`, `start`, comments and blank lines are never touched.

`doc.text()` is what is saved, and **a file opened and saved unchanged is byte-for-byte the file it
was**. After each change, `parse_schematic` reads the whole text again. The one parser stays the single
source of truth, and its messages (`line 12: '4.7q' is not a value`) are the editor's messages too.
The whole `Document` is library code, tested in the library suite with no window.

### Gestures

| doing | what it does |
|---|---|
| click a part or wire | selects it; its grid points get handles |
| shift-click | adds it to the selection, or takes it out |
| drag on empty board | selects everything inside the box |
| drag a selection | moves it by whole squares; the end of a wire touching it follows (rubber-banding), and a wire selected at both ends moves whole |
| drag a handle | moves that one point: stretches a resistor, moves a transistor's base, ends a wire somewhere else |
| press on a bare grid point and drag | draws a wire as an L, across then down; `space` mid-drag switches which leg goes first |
| a palette part, or its key (`R`, `C`, `L`, `D`, `Q`, `G`, …) | the part follows the pointer as a ghost; a click places it and keeps the tool for another; `Escape` puts the tool down |
| `r` / `f` | rotates the selection a quarter turn about its middle, snapped to the grid / mirrors it |
| `Delete`, `Backspace` | deletes the selection |
| double-click a part, or `Enter` | opens a popover at the part, with fields for its name and its value as written |
| `⌘Z`, `⇧⌘Z` | undo, redo |
| `⌘S`, `⇧⌘S` | save, save as |
| right-click a part | its menu: rotate, flip, edit, duplicate, delete |

- **Connecting is already in the format**: points join where they meet, and an end landing on a wire
  joins the wire. So a drop *is* the connection, and there is no separate connect step. A drop that
  makes a new junction is shown by the junction dot the board already draws.
- **A new part is given the next free name for its kind** (`R4` after `R3`) and a value that runs:
  1 kΩ, 1 µF, a red LED, a 2N3904, a 1 kHz sine of 1 V.
- **A value field is checked as it is committed.** `Enter` or leaving the field commits; `Escape`
  cancels. A value that does not parse is refused: the parser's message shows in red under the field,
  and the field stays open.
- **Undo keeps whole texts.** A file is a few kilobytes, so a stack of texts is simpler than a stack
  of inverse operations, and nothing about it can drift. One drag is one step, however many frames it
  took.
- **The title shows `•` while there are unsaved changes.** Quitting with any asks (*Save*, *Don't
  save*, *Cancel*), in a modal. In editing mode `Escape` cancels the tool or the drag in hand and
  never quits. Save as uses the platform's own dialog, `sh.sysl.sdl3`'s `ask_save_file`.

### The circuit follows each commit

**A drop, a placement, a deletion or a committed value is a commit.** It sends the new text to the
circuit's thread as a `Change.Replace(text)`. Both models build again from that text, and the circuit
starts again the way its file says: from empty, or settled. **Restarting is the rule, not carrying
the charge across**: a capacitor matched by name after its value or wiring changed holds a state the
new circuit never reached, and a restart is the one answer that is always a true picture of the circuit
as drawn. Some state has to survive the rebuild, and
it is carried by what still means the same thing afterwards, since element indices do not:

- meters, by their grid points;
- panel settings and the selection, by element name;
- the speed, the mute and the Bode plot, as they were.

**A drag does not rebuild.** While it is moving, the selection is drawn as a ghost without its voltages
or dots, and the rest of the circuit carries on. Rebuilding every frame would restart the circuit
sixty times a second. A text that does not parse is never committed, so the board always holds a
circuit that parses. One that parses but cannot be solved, such as a part left floating halfway
through building, *is* committed, and the status line shows the trouble as it does now: an unfinished
circuit is the normal state while editing one.

### Turning an op-amp

**An op-amp is the one part that cannot be turned today.** Its line gives only its middle, and its five
pins are fixed around it. The line gains two optional trailing words: `turned 90|180|270` (a quarter
turn clockwise for each 90) and `flipped` (its inverting input below rather than above). A line without
them reads exactly as before, so no existing file changes. A two-point part turns by rotating its
points. A transistor turns its three points, and flips by mirroring its base across the
collector–emitter line, which the format can already say. A transformer's four points turn together.

### The palette

**Down the left, in a `split_row` so it can be made narrower, and only while editing.** It is grouped
into collapsible `section`s: *Passive*, *Sources*, *Semiconductors*, *Instruments*, *Wiring*. Each part
is a `button_with` an `icon` of its symbol, with a tooltip giving its name and its key. Each icon is a
small vector drawing of the board's symbol, written once as syslui `Path`s. The board keeps drawing
through PlutoVG, so the two drawings are kept alike by eye. The icons are a sketch, not the symbol at
another size.

### The view stays put

**Running fits the drawing to the board every frame (`place`); editing must not**, or the board would
lurch every time a part moved past the edge. Entering editing mode freezes the fit, with four squares
more of room on each side. The wheel zooms around the pointer, a right-button drag pans, and `0` fits
again. Leaving editing mode fits as running always has.

### What syslui needs that it does not have

Everything else is in syslui 0.2.3 and syslui-sdl 0.2.28 already: pointer capture (`grab`, `owns`),
`drag` with a slop, `press_origin`, `pointer`, `modifiers`, `held`/`drag_by` for the right button,
`wheel`, `cursor`, `tap_count`, `popover`, `modal`, `text_field` with `on_blur`, `menu_bar`, `icon`,
`button_with`, `section`, `split_row` and `.tooltip`. Two pieces are missing, and each is added to its
own package and released before amber uses it:

1. **A menu at a point** (syslui). A dropdown today only exists under a `menu_bar` title, and the
   drawing of it (`menu.sysl`'s `dropdown`) is private. Right-clicking a part needs that dropdown at
   the pointer, closed by a tap elsewhere or by `Escape`, kept inside the window, reusing the menu's
   rows, toggles and separators: something like `context_menu(items, at: &Signal[Option[(int, int)]])`.
2. **Knowing a field has the keyboard** (syslui-sdl). `on_event` sees every key *before* the focused
   view does, and cannot ask whether one is focused. Typing `r` into a value field would then also
   rotate the part. The app loop already tracks focus (`c.focus()`, for the on-screen keyboard), so the
   piece missing is handing that to the application: either a `typing: bool` beside the event, or an
   `on_shortcut` called only for a key no field has taken.

### Tests

- **Library**: every file in `examples/` opened and saved unchanged is byte-identical. Each `Document`
  operation (move, move one point, rotate, flip, add, delete, rename, revalue, on a transformer and an
  op-amp too) yields the expected text and parses. A comment and the column alignment survive a move.
  An element moved onto a wire's middle joins its node. An op-amp `turned` and `flipped` has its pins
  where they should be, and the old lines still read the same.
- **App**: the gestures driven headless through syslui's recording canvas (`point`, `press`,
  `let_go`), which the app's tests have not used until now. Drag `R1` two squares and the text says
  so. Undo gives back the bytes. A bad value is refused with the parser's message. A drag does not
  rebuild, and a drop does. Meters and panel settings survive a commit.
- **Running mode is unchanged**: a screenshot of every example before and after must match, and any
  difference stops the work.

### Not in this item

Copy and paste between files, subcircuits, routing wires around parts, more than one file at once, and
writing a SPICE netlist out. Each can follow once this has been used.

### In what order

Each step is a branch of its own, merged when its tests pass:

1. **syslui**: a menu at a point. **syslui-sdl**: the focused field visible to the application. Both
   are released, and amber's pins move to them.
2. **Library**: `Document`, `Element.line`, the op-amp's `turned`/`flipped`, and the round-trip tests.
3. **App**: editing mode, selection, moving, handles, rubber-banding, the frozen view, `Replace`,
   undo, save. The most important step: everything after it is additions.
4. **App**: drawing wires, the palette, placing parts, rotate/flip/delete, the value popover, the
   right-click menu, the unsaved-changes modal.

## Roadmap

Each is a piece of work of its own, in this order.

1. ~~DC operating point: R, V, I, diode/LED; schematics; the viewer with voltmeters.~~
2. ~~**Transient analysis**: capacitors and inductors (trapezoidal, backward Euler at corners),
   sources with waves (dc, sine, pulse/square, PWL), switches, step control from the error against a
   parabola through the last three points, with rejected steps; the incremental API (`power_on`,
   `advance_to`, `set_switch`, `set_wave`). The viewer runs the clock, animates current, and has a
   scope of every meter.~~
3. ~~**SPICE netlists**: read a `.cir` subset (elements, `.model`, `.op`, `.tran`, `.dc`), with ngspice
   as the oracle; `amber-cli` runs one.~~
4. **Active devices**: ~~BJT (Gummel–Poon transport and Early terms) in the library and netlists
   (`Q` cards, `.model NPN|PNP`), held to ngspice on a biased amplifier, a mirror, a switch and an
   astable multivibrator; the transistor in schematics and the viewer, with an astable multivibrator
   blinking two LEDs; MOSFET level 1 in the library and netlists (`M` cards, `.model NMOS|PMOS`),
   held to ngspice on a common-source stage, a CMOS inverter's transfer curve and an LED switch; the
   MOSFET in schematics and the viewer, with a CMOS inverter lighting an LED.~~
   ~~**Bench instruments**: a signal generator (sine, square, triangle, dc; frequency, amplitude,
   offset, output resistance) in schematics, with a panel in the viewer that retunes it while the
   clock runs, and a common-emitter amplifier held to ngspice; a bench power supply (CV/CC, and raw
   with mains ripple and sag) on the same panel, a zener (BV, IBV) held to ngspice, and a zener shunt
   regulator and an emitter-follower regulator, the latter held to ngspice.~~
5. ~~**DC sweep and AC analysis**: `.dc` sweeps a source; `.ac` and `Sim.response` linearise the
   circuit at its operating point (the Newton system written there is every part's slope) and solve
   it with `jωC` and `jωL` added, by the same LU generic over its entry (`real` through time,
   `Complex[real]` here, pivoting on each entry's size), held to ngspice on an RLC band-pass and
   bipolar and MOSFET amplifiers; the viewer's Bode plot, each meter's gain and phase driven from the
   generator.~~
6. ~~**Sparse LU.** Each pivot is chosen by Markowitz's rule — fewest others in its row and column —
   among those at least half the largest in their column, and the elimination is recorded as it
   goes: the pivot's place, the entries under it and right of it, and where each product lands.
   Every later solve replays that list, and a pivot gone unsound replans only from its own step,
   the steps before it already done. The matrix stays dense in storage, so a stamp is an index, and
   clearing touches only the entries ever written. On `examples/moog.amber` (44 unknowns) a
   factorisation is 99 products where the numbered order made over 4,000, and the circuit runs 2.4×
   faster, about five times real time on an idle machine; `amber-app <file> --bench <seconds>`
   reports the products and how often the order was replanned.~~
7. **Editing in the viewer**: place, move, rotate and delete parts; edit values; save. The design is
   **Editing** above, in four steps.
8. **Benchtop's analog layer**, measured against the H747 real-time bar.
