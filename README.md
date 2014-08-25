kk_launchpad
============

A small library for interacting with the Novation Launchpad MIDI
controller using Ruby. Supports LED setting, duty cycle setting,
double buffering, flashing, and offline updates with rapid uploads.

Currently uses `unimidi` for cross-platform MIDI access, but the
MIDI library can easily be changed by redefining two or three
methods (`send_midi`, `each_incoming_message`, and optionally
`LaunchpadMIDI.device`).

Some example programs, such as Game of Life on the Launchpad, are
included.

~ [Kimmo Kulovesi](http://arkku.com/), 2014-08-24

Usage by Example
================

Basic setup
-----------

Basic setup with a single connected device (manual selection using
the chosen MIDI library must be implemented for more than one
simultaneously connected Launchpad):

    lp = LaunchpadMIDI.device
    lp.reset
    lp.set_duty_cycle(1, 4)         # 1/4 for less flickering

The above setup is assumed for all further examples.


Setting LEDs
------------

Setting LEDs (the arguments are `column`, `row`, `red`, and `green`):

    lp.set_led_colors(0, 0, 3, 0)   # top left square pad red
    lp.set_led_colors(7, 7, 0, 3)   # bottom right square pad green
    lp.set_led_colors(8, 7, 2, 2)   # bottom right round button amber
    lp.set_led_colors(7, -1, 3, 3)  # "mixer" button yellow

The square pads occupy rows `0..7` and columns `0..7`. On rows `0..7` the
right side round buttons occupy column `8`. The top row of round pads is
row `-1` (negative one), with columns `0..7`.

The red and green LEDs can each be set to four different brightness
values: `0..3`, for a total of 15 colors of light (both zero is the
off state).


Double Buffering
----------------

The Launchpad supports hardware double buffering. When enabled, any
changes to LEDs are sent to a non-displayed "buffer" on the device.
This non-displayed buffer can then be shown with a single command,
giving the appearance of all buffered changes taking place instantaneously,
while the previously displayed buffer becomes the non-displayed background
buffer for future updates. The two buffers are thus repeatedly "flipped"
between update and display states.

    lp.double_buffer = true

    # Turn all LEDs green:
    0.upto(7) do |row|
      0.upto(7) do |column|
        lp.set_led_colors(column, row, 0, 3)
      end
    end
    lp.flip_buffers # all LEDs change at once

Double buffering is used to eliminate visible "scanning" or flicker when
large numbers of LEDs are updated. It does not matter how long it takes
to update the background buffer: all changes take place at once when the
buffers are flipped. However, the framerate of such updates may still be
poor due to the relatively slow speed of MIDI on the Launchpad.

Calling `flip_buffers` copies the buffer that will be displayed into the
new background buffer by default. This means that the user need not worry
about keeping the two buffers in sync. However, if it is desired to animate
between two buffers (e.g., to blink between two states) the parameter
`false` to `flip_buffers` disables copying of the buffer:

    lp.double_buffer = true
    
    # Turn the top left square pad green in the background buffer:
    lp.set_led_colors(0, 0, 0, 3)
    lp.flip_buffers(false)
    
    # Turn the pad red in the _new_ background buffer:
    lp.set_led_colors(0, 0, 3, 0)
    
    # Animate by flipping without copying:
    loop do
      lp.flip_buffers(false)
      sleep 0.5
    end


Rapid Updates
-------------

For faster animations of large numbers of LEDs it is possible to use a
rapid update feature on the Launchpad, which updates all the LEDs in
order. This library supports the rapid update feature by means of
offline buffering, i.e., updates are buffered on the computer instead
of being sent to the Launchpad, and then the entire state is
uploaded with the rapid method when `update` is called:

    lp.offline_updates = true

    # Turn all LEDs green:
    0.upto(7) do |row|
      0.upto(7) do |column|
        lp.set_led_colors(column, row, 0, 3)
      end
    end
    lp.set_led_colors(0, 0, 3, 0) # turn the top left pad red
    lp.update                     # update all LED states to the Launchpad

In the above example it should be noted that the top left square pad
is first set green and then red, but the green color is never seen
on the Launchpad because offline updates were enabled and `update` was
called only after it had been set red.

Offline updates are several times faster than online updates of every
LED, and thus recommended for animation or whenever about a quarter or
more of the LEDs need to be changed in one go. Offline updates can be
combined with double buffering to eliminate any residual "scanning":

    lp.double_buffer = true
    lp.offline_updates = true
    0.upto(7) do |row|
      0.upto(7) do |column|
        lp.set_led_colors(column, row, 0, 3)
      end
    end
    lp.update       # FIRST upload the changes to the background buffer...
    lp.flip_buffers # ...then flip the buffers

Note that both `update` and `flip_buffers` must be called, in that order,
before changes are visible. The reason is that offline updates need to
be uploaded with `update`, but with double buffering enabled the updates
go into the non-displayed buffer and are not visible until the buffers
are flipped with `flip_buffers`.


Flashing
--------

Flashing LEDs can obviously be implemented in software by repeatedly
updating the color. However, the Launchpad supports hardware flashing,
which is done by automatically flipping between the two buffers. This
makes it incompatible with double buffering.

    lp.flashing = true  # enable hardware flashing

    # The fourth parameter in `set_led_colors` makes the LED flash:
    lp.set_led_colors(0, 0, 3, 3, true) # flash top left square pad yellow


Input
-----

The Launchpad sends MIDI note on messages when the square pads or the
round side buttons are pressed, and control change messages when the
top row of square buttons are pressed. The note on/off messages can
be mapped either in X/Y mode (having the X/Y position encoded directly
into the note number) or "drum rack" mode (with more "playable" note
numbers). The library supports either mode transparently:

    lp.set_xy_mapping         # default after reset
      # or
    lp.set_drum_rack_mapping

The only effect of switching to drum rack mapping is in the MIDI
messages themselves, usage of this library is not affected since
it deals in column/row coordinates.

To receive input from the Launchpad it is possible to either skip
this library altogether and simply access it like any other MIDI input
device. However, for mapping MIDI messages to column/row coordinates,
the library provides the convenience method `each_action`, which yields
each currently pending button press:

    loop do
      lp.each_action do |column, row, pressed|
        if pressed
          puts "Button at (#{column}, #{row}) down"
        else
          puts "Button at (#{column}, #{row}) up"
        end
      end
    end

