# amber

An analog circuit simulator in [sysl](https://sysl.sh), and a viewer that draws the circuit with the
voltage on every wire. Named for *ēlektron*, the Greek for amber, which is where the word
"electricity" comes from.

![A battery, a resistor and an LED, with three voltmeters](shot.png)

## The viewer

```
sysl build app
app/amber-app examples/led.amber
```

Wires are grey at ground, warming to amber as their voltage rises (and cooling to blue below ground).
**Click two grid points to put a voltmeter across them** — the red lead first, the black lead second;
it reads the first point's voltage less the second's. Click a part for the voltage across it, the
current through it and the power it takes or delivers. `v` toggles the voltage beside every part, `c`
clears the meters, Escape quits.

`--shot out.png` draws one frame to a PNG without a window, and `--meter x1,y1,x2,y2` places a meter
from the command line.

## Schematics

A schematic is one element per line, placed on a grid; elements whose ends meet are connected, and an
end landing anywhere along a wire joins it:

```
# A battery, a resistor and an LED.
battery  B1   0 0  0 6  9V       # + end first
resistor R1   0 0  6 0  470
led      D1   6 0  6 6  red      # anode first
wire          6 6  0 6
ground        0 6
meter    M2   6 0  6 6           # red lead first
```

Kinds: `wire`, `resistor`, `battery`, `current`, `diode`, `led` (`red`, `yellow`, `green`, `blue`),
`ground`, `label` (names a node), `meter`. Values take SPICE's suffixes: `4.7k`, `10u`, `1meg` (and
`1m` is a milliohm).

## The library

`sh.sysl.amber` builds a circuit — from a schematic, or part by part — and solves it by modified
nodal analysis, with Newton–Raphson and SPICE's junction limiting for diodes:

```
dependencies {
  amber { git = "github.com/sysl-lang/amber", version = "0.1.0" }
}
```

```sysl
import sh.sysl.amber.{circuit, sim, VoltageSource, Resistor, Diode, RED_LED}

var c = circuit()

c.connect("B1", VoltageSource(9.0), "plus", "0")
c.connect("R1", Resistor(470.0), "plus", "anode")
c.connect("D1", Diode(RED_LED), "anode", "0")

var s = sim(c)

s.operating_point().unwrap()
print(s.across(2), s.current(1))
```

It needs nothing but an allocator. What is planned is in [DESIGN.md](DESIGN.md).

```
sysl test .
```

runs both the library's tests and the viewer's.
