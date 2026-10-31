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
source (and, coming, per inductor), plus an inner node per diode with series resistance. Nonlinear
parts are linearised about the present solution and the system re-solved until neither the unknowns
nor any junction voltage moves (relative 1e-6, absolute 1e-9). Junction steps are limited as SPICE's
`pnjlim` does. If plain Newton fails, gmin stepping: a shunt from every node to ground, removed a
decade at a time.

A diode's reported current is read off the line the last system was linearised on, so KCL holds
exactly at every node in what is reported.

A part has two terminals (`a`, `b`) or three (`a`, `b`, `c`; `c` is -1 on a two-terminal part). A
bipolar transistor is SPICE's Gummel–Poon model reduced to its transport and Early terms (IS, BF, BR,
NF, NR, VAF, VAR), NPN or PNP, with GMIN across each junction in the base current as SPICE puts it. Its
two junctions, base–emitter and base–collector, are each limited by `pnjlim` on the bare thermal
voltage, and the collector and base currents are each linearised against both; the emitter carries
both back out. Its terminal currents are read off the linearisation like a diode's.

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
   astable multivibrator;~~ the transistor in schematics and the viewer, with an astable multivibrator
   blinking two LEDs; MOSFET level 1.
5. **DC sweep and AC analysis** (complex MNA, Bode plot in the viewer).
6. **Sparse LU** with a symbolic factorisation reused across iterations and steps.
7. **Editing in the viewer**: place, move, rotate and delete parts; edit values; save.
8. **Benchtop's analog layer**, measured against the H747 real-time bar.
