// Copyright (C) 2026 Toit Contributors. All rights reserved.
// Use of this source code is governed by a MIT-style license that can be found
// in the LICENSE file.

import gpio
import log
import pulse-counter

/**
Driver for a rotary encoder with push switch.

Rotation is decoded with the ESP32 pulse counter (PCNT) in quadrature mode:
  the CLK pin is the counting pin (both edges), and the DT pin is the control
  pin with $pulse-counter.Channel.CONTROL-INVERSE when high.  With this
  configuration mechanical contact bounce cancels itself out: a bounce on CLK
  produces matching increment/decrement pairs (net zero), and bounce on DT is
  ignored entirely since control pins never count.  The hardware glitch
  filter additionally suppresses sub-microsecond electrical noise.

The switch is debounced in software with a settle-and-verify loop around
  $gpio.Pin.wait-for.

Runs as background tasks and calls the registered lambdas when the
  corresponding event occurs.
*/
class Rotaryencoder:
  static CW ::= 0
  static CCW ::= 1
  static DOWN ::= 2
  static UP ::= 3

  clk-pin_/int
  dt-pin_/int
  sw_/gpio.Pin

  lambdas_/Map := {:}
  holds_/Map := {:}  // Threshold in microseconds -> Lambda.
  tasks_/Map := {:}
  unit_/pulse-counter.Unit? := null
  logger_/log.Logger

  poll-ms_/int
  counts-per-detent_/int
  invert_/bool
  debounce-ms_/int

  /**
  Constructs the driver.

  The $clk-pin and $dt-pin are handed to the pulse counter when $start is
    called; they must not be in use elsewhere.

  The $counts-per-detent depends on the encoder model.  A typical detented
    encoder (for example an EC11) produces one full CLK cycle per detent,
    which yields 2 counts with both-edge decoding.  Adjust if one physical
    detent produces multiple (or half) events.

  If $invert is true, the CW and CCW directions are swapped.  Use this if
    the reported direction doesn't match the physical rotation.

  The $poll-ms is the sleep between counter reads in the rotation task.
    Lower values reduce latency at the cost of more (cheap) wake-ups.

  The $debounce-ms is the time the switch must hold a level before an edge
    is accepted.  Increase it if release bounce causes phantom press cycles
    (visible as a spurious DOWN/UP pair right after releasing).
  */
  constructor
      --clk-pin/int
      --dt-pin/int
      --sw-pin/int
      --counts-per-detent/int=2
      --invert/bool=false
      --poll-ms/int=10
      --debounce-ms/int=20
      --logger/log.Logger=log.default:
    logger_ = logger.with-name "rotary-encoder"
    clk-pin_ = clk-pin
    dt-pin_ = dt-pin
    counts-per-detent_ = counts-per-detent
    invert_ = invert
    poll-ms_ = poll-ms
    debounce-ms_ = debounce-ms
    sw_ = gpio.Pin sw-pin --input --pull-down

  /**
  Starts the background tasks for the registered events.

  Only starts the tasks that have at least one registered lambda, so call
    $add before calling this method.
  */
  start -> none:
    if lambdas_.contains DOWN or lambdas_.contains UP or not holds_.is-empty:
      tasks_["switch"] = task:: switch-task_
    if lambdas_.contains CW or lambdas_.contains CCW:
      unit_ = pulse-counter.Unit clk-pin_
          --on-positive-edge=pulse-counter.Channel.EDGE-INCREMENT
          --on-negative-edge=pulse-counter.Channel.EDGE-DECREMENT
          --control-pin=dt-pin_
          --when-control-low=pulse-counter.Channel.CONTROL-KEEP
          --when-control-high=pulse-counter.Channel.CONTROL-INVERSE
          --glitch-filter-ns=12_500
      tasks_["encoder"] = task:: encoder-task_

  /** Stops the background tasks and releases the pulse counter. */
  stop -> none:
    tasks_.get "switch" --if-present=: | t |
      t.cancel
      logger_.info "stopping switch task"
    tasks_.get "encoder" --if-present=: | t |
      t.cancel
      logger_.info "stopping encoder task"
    tasks_ = {:}
    if unit_:
      unit_.close
      unit_ = null

  encoder-task_ -> none:
    // Accumulates raw counts until a full detent has been reached, then
    // emits one event per detent.  Bounce cancels in the hardware counter,
    // so no software debounce is needed here.
    accumulated := 0
    while true:
      sleep --ms=poll-ms_
      delta := unit_.value
      if delta == 0: continue
      unit_.clear  // Note: counts arriving between value and clear are lost.
      if invert_: delta = -delta
      accumulated += delta
      while accumulated >= counts-per-detent_:
        accumulated -= counts-per-detent_
        lambdas_.get CW --if-present=: it.call
      while accumulated <= -counts-per-detent_:
        accumulated += counts-per-detent_
        lambdas_.get CCW --if-present=: it.call

  switch-task_ -> none:
    // If the task starts while the button is already pressed (for example
    // after a stop/start issued from within a hold lambda), wait for the
    // release first: the ongoing press belongs to the previous task's
    // cycle and must not be counted again.
    if sw_.get == 0: wait-stable_ sw_ 1
    while true:
      wait-stable_ sw_ 0
      lambdas_.get DOWN --if-present=: it.call
      start-us := Time.monotonic-us
      thresholds := holds_.keys.sort
      hold-fired := false
      released := false
      thresholds.do: | threshold-us/int |
        if released or hold-fired: continue.do
        remaining-us := threshold-us - (Time.monotonic-us - start-us)
        if remaining-us > 0:
          exception := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
            with-timeout --us=remaining-us:
              wait-stable_ sw_ 1
          if exception == null:
            released = true
            // Fire the largest threshold that was reached; a press shorter
            // than the smallest threshold counts as the smallest.
            held-us := Time.monotonic-us - start-us
            best-us := thresholds.first
            thresholds.do: | t/int |
              if held-us >= t: best-us = t
            logger_.debug "released after $(held-us / 1_000)ms, firing $(best-us / 1_000)ms hold"
            holds_[best-us].call
            hold-fired = true
            continue.do
        if threshold-us == thresholds.last:
          // The longest threshold was reached while still held: no longer
          // threshold can override it, so fire immediately.
          logger_.debug "longest hold threshold of $(threshold-us / 1_000)ms reached"
          holds_[threshold-us].call
          hold-fired = true
      if not released:
        // Wait out the release; no further hold can fire.
        wait-stable_ sw_ 1
      lambdas_.get UP --if-present=: it.call
      // Quiet period before re-arming: late release rebounds within this
      // window cannot start a phantom press cycle.
      sleep --ms=(debounce-ms_ * 3)

  /**
  Waits until $pin has settled at $level.

  Waits for the level, then verifies that the pin still holds it after
    $debounce-ms_ milliseconds.  Retries as long as the pin has bounced away
    again.
  */
  wait-stable_ pin/gpio.Pin level/int -> none:
    while true:
      pin.wait-for level
      sleep --ms=debounce-ms_
      if pin.get == level: return

  /**
  Registers the lambda $code for the event $function.

  The $function must be one of $CW, $CCW, $DOWN, or $UP.
  Replaces a previously registered lambda for the same event.
  */
  add function/int code/Lambda -> none:
    assert: CW <= function <= UP
    lambdas_[function] = code

  /** Removes the lambda registered for the event $function. */
  clear function/int -> none:
    assert: CW <= function <= UP
    lambdas_.remove function

  /**
  Registers the lambda $code as a hold event with threshold $duration.

  Exactly one hold lambda fires per press when any holds are registered:
  - A press shorter than the smallest registered threshold fires the
    *smallest* hold on release — the smallest threshold is the catch-all
    "click" bucket.
  - A release between thresholds fires the largest threshold that was
    reached, on release.
  - The *longest* registered threshold fires live, the moment it is
    reached, since no longer hold can override it.

  With thresholds of 5 s and 15 s: a 0.3 s click and an 8 s hold both fire
    the 5 s lambda (at release); holding to the 15 s mark fires the 15 s
    lambda immediately.

  Hold events are independent of $DOWN and $UP, which always fire at their
    edges.  In particular a registered $UP lambda fires *in addition to*
    the hold lambda on every release; register either $UP or holds, not
    both, unless that is intended.

  Replaces a previously registered lambda for the same $duration.
  */
  add-hold duration/Duration code/Lambda -> none:
    assert: duration > Duration.ZERO
    holds_[duration.in-us] = code

  /** Removes the hold lambda registered for $duration. */
  clear-hold duration/Duration -> none:
    holds_.remove duration.in-us
