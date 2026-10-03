# Toit driver for rotary encoders with a push switch

A small Toit driver for the common mechanical rotary encoder with a push
button (the EC11 style found on most breakout modules and in a lot of
knobs).  It runs in the background and calls a Toit
[Lambda](https://docs.toit.io/language/blocks-and-lambdas) when the knob is
turned, or the button is pressed, released or held.

## Quickstart
For a quick overview and to get started, see the [examples](./examples/).

## Features

- **Rotation** is decoded by the ESP32's hardware pulse counter (PCNT) in
  quadrature mode, rather than by polling the pins.  The CLK pin is the counting
  pin (both edges) and the DT pin steers the direction.  Mechanical contact
  bounce on CLK produces matching increment/decrement pairs that cancel out, and
  bounce on DT is ignored, so no software debouncing of the rotation is needed.
  A hardware glitch filter removes very short electrical noise as well.
- **One event per detent.**  Raw counts are accumulated until a full detent has
  been turned, then one clockwise (`CW`) or counter-clockwise (`CCW`) lambda is
  called per click of the knob.
- **Push switch** is debounced in software (it waits for the level, then checks
  that it is still there after a settle time).  Lambdas can be set for the
  button going down (`DOWN`) and coming back up (`UP`).
- **Hold events**: lambdas can be registered against press durations, so one
  button can do different things for a click, a medium hold and a long hold.
- Only the tasks needed are started: if nothing is registered for rotation, the
  pulse counter is not claimed, and if nothing is registered for the button, the
  switch task does not run.

## Usage

Add the lambdas first, then call `start`:
```Toit
import rotaryencoder show *

main:
  encoder := Rotaryencoder --clk-pin=20 --dt-pin=19 --sw-pin=17

  encoder.add Rotaryencoder.CW  (:: print "turned clockwise")
  encoder.add Rotaryencoder.CCW (:: print "turned counter-clockwise")
  encoder.add Rotaryencoder.DOWN (:: print "button down")
  encoder.add Rotaryencoder.UP   (:: print "button up")

  encoder.start
```

Wiring: CLK, DT and SW go to three GPIO pins; the common pin goes to GND (check
your module, VCC is usually only needed for the pull-up resistors some boards
carry).  The switch pin is configured with an internal pull-down, so the switch
is expected to drive the pin **high** when pressed.

`stop` cancels the tasks and releases the pulse counter.

### Constructor options

| Option | Default | What it does |
|---|---|---|
| `--counts-per-detent` | 2 | Counts the pulse counter sees per click of the knob.  A typical detented EC11 gives 2 with both-edge counting.  If one click gives several events (or you need two clicks for one event) adjust this. |
| `--invert` | false | Swaps `CW` and `CCW`, if the direction does not match the knob. |
| `--poll-ms` | 10 | How often the counter is read.  Lower is quicker to respond, higher is quieter. |
| `--debounce-ms` | 20 | How long the switch must hold a level before it is accepted.  Raise it if a release causes a phantom down/up pair. |

### Hold events
`add-hold` takes a duration and a lambda.  When any holds are registered,
exactly one hold lambda fires per press:

- A press shorter than the shortest threshold fires the *shortest* hold, on
  release.  The shortest threshold is the "click" bucket.
- A release between two thresholds fires the longest threshold that was
  reached, on release.
- The *longest* threshold fires immediately when it is reached, while the
  button is still held, as nothing longer can override it.

```Toit
// Click (under 5 s) and 5 s to 15 s holds fire on release; the 15 s hold
// fires the moment 15 seconds is reached.
encoder.add-hold (Duration --ms=1) (:: print "click")
encoder.add-hold (Duration --s=5)  (:: print "held 5 s")
encoder.add-hold (Duration --s=15) (:: print "held 15 s")
```
Hold lambdas do not replace `DOWN` and `UP`: those always fire at their edges as
well.  If you use holds, usually leave `UP` unregistered, or it will fire in
addition to the hold on every release.

`clear` and `clear-hold` remove a registered lambda.

## Things to be aware of

- The lambdas are called from the driver's own background tasks, so keep them
  short and avoid blocking in them.
- The CLK and DT pins are given to the pulse counter when `start` is called and
  must not be used for anything else.
- Counts that arrive between the driver reading and clearing the counter are
  lost (noted in the source).  At the default poll interval this should not be
  noticeable for a hand-turned knob, but a very fast spin could in theory lose a
  click.
- The ESP32 pulse counter is used, so this is intended for ESP32 variants that
  have one.

## Issues
If there are any issues, changes, or any other kind of feedback, please
[raise an issue](https://github.com/milkmansson/toit-rotaryencoder/issues).
Feedback is welcome and appreciated!

## Disclaimer
- This driver has been written and tested with a generic rotary encoder module
  with a push switch.
- All trademarks belong to their respective owners.
- No warranties for this work, express or implied.

## Credits
- [Florian](https://github.com/floitsch) for the tireless help and encouragement
- The wider Toit developer team (past and present) for a truly excellent product

## About Toit
One would assume you are here because you know what Toit is.  If you dont:
> Toit is a high-level, memory-safe language, with container/VM technology built
> specifically for microcontrollers (not a desktop language port). It gives fast
> iteration (live reloads over Wi-Fi in seconds), robust serviceability, and
> performance that’s far closer to C than typical scripting options on the
> ESP32. [[link](https://toitlang.org/)]
- [Review on Soracom](https://soracom.io/blog/internet-of-microcontrollers-made-easy-with-toit-x-soracom/)
- [Review on eeJournal](https://www.eejournal.com/article/its-time-to-get-toit)
- Toit on [Wikipedia](https://en.wikipedia.org/wiki/Toit).
