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
not a variant of `Wave`: the solver already lands a step on each of a pulse's corners, a netlist
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
   `Complex[real]` here, pivoting on `Magnitude`), held to ngspice on an RLC band-pass and bipolar and
   MOSFET amplifiers; the viewer's Bode plot, each meter's gain and phase driven from the generator.~~
6. **Sparse LU** with a symbolic factorisation reused across iterations and steps. The measured need:
   `examples/moog.amber`, 38 unknowns stepped at the speaker's 48 kHz, is worked out at about half
   real time on the dense solver (59,000 accepted steps a second of sound), where the smaller audio
   circuits run four to sixteen times faster than real time.
7. **Editing in the viewer**: place, move, rotate and delete parts; edit values; save.
8. **Benchtop's analog layer**, measured against the H747 real-time bar.
