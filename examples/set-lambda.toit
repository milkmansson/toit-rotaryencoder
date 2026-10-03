// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import rotaryencoder show *

// Set up our pins.  VCC and GND must also be connected.
CLK-PIN ::= 20
DT-PIN  ::= 19
SW-PIN  ::= 17

main:
  // Instantiate encoder.
  encoder := Rotaryencoder --clk-pin=CLK-PIN --dt-pin=DT-PIN --sw-pin=SW-PIN

  // Set the Lambdas.
  //encoder.add Rotaryencoder.DOWN (:: print "Button DOWN")
  //encoder.add Rotaryencoder.UP (:: print "Button UP")
  encoder.add Rotaryencoder.CW (:: print "ENCODER CW")
  encoder.add Rotaryencoder.CCW (:: print "ENCODER CCW")

  // Holds-only pattern: exactly one of these fires per press.  A click or
  // hold under 5s fires the first (on release); 5-15s fires the second (on
  // release); reaching the 15s mark fires the third live.  UP is left
  // unregistered on purpose: it would fire in addition to the hold on
  // every release.
  encoder.add-hold (Duration --ms=1) (:: print "CLICK (under 5s)")
  encoder.add-hold (Duration --s=5) (:: print "HELD 5s")
  encoder.add-hold (Duration --s=15) (:: print "HELD 15s")

  // Start the driver.
  encoder.start

  // Nothing to do as the driver executes the print lambdas in this example.
