#!/usr/bin/env ruby
# kk_launchpad.rb: A Ruby library for the Novation Launchpad.
# The author is in no way affiliated with Novation DMS Ltd, this is
# an unofficial library made based on publicly released documentation.
#
# Currently this uses `unimidi` for cross-platform MIDI access, but
# it can be easily changed by redefining `send_midi` and
# `each_incoming_message`. Device selection with `Launchpad.device`
# works if there is exactly one Launchpad device connected, otherwise
# results may be unpredictable. Manual device selection should be
# if support for multiple Launchpads is required.
#
# Copyright (c) 2014-2015 Kimmo Kulovesi, http://arkku.com/
# Use and distribute freely.
# Mark modified copies as such, do not remove the original attribution.
# ABSOLUTELY NO WARRANTY - USE AT YOUR OWN RISK ONLY!
##############################################################################
require 'rubygems'
require 'unimidi'

class LaunchpadMIDI

  DEVICE_NAME_RE = /^(Novation|Focusrite).* Launchpad.*/
  DRUM_RACK_NOTES = [
    64, 65, 66, 67,  96, 97, 98, 99,   100,
    60, 61, 62, 63,  92, 93, 94, 95,   101,
    56, 57, 58, 59,  88, 89, 90, 91,   102,
    52, 53, 54, 55,  84, 85, 86, 87,   103,
    48, 49, 50, 51,  80, 81, 82, 83,   104,
    44, 45, 46, 47,  76, 77, 78, 79,   105,
    40, 41, 42, 43,  72, 73, 74, 75,   106,
    36, 37, 38, 39,  68, 69, 70, 71,   107
  ]
  DRUM_NOTE_TO_XY = {} unless defined? DRUM_NOTE_TO_XY
  if DRUM_NOTE_TO_XY.empty?
    DRUM_RACK_NOTES.each_slice(9).each_with_index do |s, row|
      s.each_with_index do |drum_note, column|
        DRUM_NOTE_TO_XY[drum_note] = row * 0x10 + column
      end
    end
  end

  NOVATION_MANUFACTURER_ID = [ 0x00, 0x20, 0x29 ]

  LAUNCHPAD_DEVICE_ID = {
    [ 0x20, 0x00 ] => :launchpad_s,
    [ 0x69, 0x00 ] => :launchpad_mk2,
    [ 0x51, 0x00 ] => :launchpad_pro,
    [ 0x36, 0x00 ] => :launchpad_mini
  }

  attr_accessor :midi_to
  attr_accessor :midi_from

  def initialize(midi_out, midi_in = nil)
    @midi_from = midi_in
    @midi_to = midi_out
    @last_command = nil
    @mapping = :xy
    @double_buffer = false
    @offline_updates = nil
  end

  # Reset the Launchpad to default settings with all LEDs off
  def reset
    send_midi(0xB0, 0x00, 0x00)
    @last_command = nil
    @mapping = :xy
    @double_buffer = false
  end

  # Set X-Y mapping for pads
  def set_xy_mapping
    send_midi(0xB0, 0x00, 0x01)
    @mapping = :xy
  end

  # Set drum rack mapping for pads
  def set_drum_rack_mapping
    send_midi(0xB0, 0x00, 0x02)
    @mapping = :drum_rack
  end

  # Is X-Y mapping enabled?
  def xy_mapping?
    @mapping == :xy
  end

  # Toggle between X-Y mapping and drum rack mapping
  def xy_mapping=(enable)
    if enable
      set_xy_mapping
    else
      set_drum_rack_mapping
    end
  end

  # Set LED duty cycle to numerator/denominator where the ranges
  # are are:
  #   numerator   1..16
  #   denominator 3..18
  def set_duty_cycle(numerator, denominator)
    if numerator < 1
      numerator = 1
    elsif numerator > 16
      numerator = 16
    end
    if denominator < 3
      denominator = 3
    elsif denominator > 18
      denominator = 18
    end
    if numerator < 9
      send_midi(0xB0, 0x1E, (0x10 * (numerator - 1)) + (denominator - 3))
    else
      send_midi(0xB0, 0x1F, (0x10 * (numerator - 9)) + (denominator - 3))
    end
  end

  # Set the LED at (column, row) to the given settings:
  #   bits 0..1   red brightness 0..3
  #   bit  2      copy to both buffers
  #   bit  3      clear other buffer's copy unless bit 2 is set
  #   bits 4..5   green brightness 0..3
  #
  # Row 0 is the first row of square pads, row 7 the last.
  # Column 0 is the first column of square pads, row 7 the last.
  # Row -1 is the top row of round buttons.
  # Column 8 is the rightmost column of round buttons.
  def set_led(column, row, bits)
    if column < 0
      column = 0
    elsif column > 8
      column = 8
    end
    if @offline_updates
      # rapid updates have a different mapping
      if row >= 0 && row < 8
        if column < 8
          @offline_updates[row * 8 + column] = bits
        else
          @offline_updates[8 * 8 + row] = bits
        end
      else
        @offline_updates[9 * 8 + column] = bits
      end
    else
      send_midi(*midi_command_for_position(column, row), bits)
    end
  end

  # Set a LED to given red and green brightness (both 0..3)
  def set_led_colors(column, row, red, green, flash = false)
    bits = ((green & 0x03) << 4) | (red & 0x03)
    bits |= (flash ? 0x08 : (@double_buffer ? 0x00 : 0x0C))
    set_led(column, row, bits)
  end

  # Turn off a LED
  def set_led_off(column, row)
    set_led(column, row, (@double_buffer ? 0x00 : 0x0C))
  end

  # Turn off all LEDs (resetting also turns them off, but this keeps
  # other settings and supports offline updates)
  def set_all_off
    data = Array.new(80, (@double_buffer ? 0x00 : 0x0C))
    if @offline_updates
      @offline_updates = data
    else
      send_midi(0x92, *data)
    end
  end

  # Set double buffering state
  #   display_buffer = 0 or 1   (buffer being displayed)
  #   update_buffer = 0 or 1    (buffer being written to)
  #   flash = true/false        (automatically toggle between buffers)
  #   copy = true/false         (if true, copy display buffer to update buffer)
  def set_buffers(display_buffer, update_buffer, flash = false, copy = false)
    bits = ((display_buffer != 0) ? 0x01 : 0) |
           ((update_buffer != 0) ?  0x04 : 0) |
           (flash ?                 0x08 : 0) |
           (copy ?                  0x10 : 0) | 0x20
    send_midi(0xB0, 00, bits)
  end

  # Toggle flashing on/off (incompatible with double buffering!)
  def flashing=(enable)
    if enable || !@double_buffer
      @double_buffer = false
      set_buffers(0, 0, enable, !enable)
    end
  end

  # Toggle double buffering on/off
  def double_buffer=(enable)
    if enable
      @double_buffer = :buffer1
      set_buffers(1, 0, false, true)
    else
      @double_buffer = false
      set_buffers(0, 0, false, true)
    end
  end

  # Is double buffering enabled?
  def double_buffer?
    @double_buffer ? true : false
  end

  # Flip the buffers (if double buffering is enabled)
  def flip_buffers(copy_buffers = true)
    case @double_buffer
    when :buffer0
      set_buffers(1, 0, false, copy_buffers)
      @double_buffer = :buffer1
    when :buffer1
      set_buffers(0, 1, false, copy_buffers)
      @double_buffer = :buffer0
    else
    end
  end

  # Toggle offline updates. If offline updates are enabled, LED states
  # are only updated into an offline buffer, not sent to the Launchpad
  # until `update` is called.
  def offline_updates=(enable)
    if enable
      @offline_updates = Array.new(80) unless @offline_updates
    else
      @offline_updates = nil
    end
  end
  
  # Is offline update enabled?
  def offline_updates?
    @offline_updates ? true : false
  end

  # Update the offline LED states to the Launchpad (if offline updates
  # are enabled)
  def update
    return unless @offline_updates
    zero_state = @double_buffer ? 0x00 : 0x0C
    @offline_updates = @offline_updates[0..79]
    data = @offline_updates.collect {|bits| bits ? bits : zero_state }
    if @last_command == 0x92
      # reset the cursor by sending another command
      self.xy_mapping = self.xy_mapping?
    end
    data.each_slice(8) do |bytes|
      #@last_command = nil
      send_midi(0x92, *bytes)
    end
  end

  # The column and row for a given MIDI note number
  def xy_for_note(note)
    note = DRUM_NOTE_TO_XY[note] if @mapping != :xy
    return nil, nil if !note || (note > 0x7F)
    return (note & 0x0F), ((note >> 4) & 0x0F)
  end

  # The column and row (always -1) for a given controller number
  def xy_for_controller(controller)
    return nil, nil if !controller || controller < 0x68 || controller > 0x6F
    return (controller - 0x68), -1
  end

  # The column, row, and action for the MIDI message (array of bytes).
  # The action is true if the button was pressed down, false if released.
  # Additionally the SysEx device inquiry message is parsed, in which
  # case `column` and `row` are both `nil`, and `action` is a symbol
  # denoting the type of device:
  #
  #    :launchpad_s
  #    :launchpad_mk2
  #    :launchpad_pro
  #    :launchpad_mini
  #    :unknown_novation_device
  #    :unknown_device
  #
  # Note that the original Launchpad does not respond to device inquiry
  # and cannot be identified by this method (however, it can usually be
  # identified by its USB id as it does not have other MIDI connectivity).
  #
  # (It is assumed that MIDI running status and realtime messages are handled
  # before passing the message to this method, i.e., the message must begin
  # with a status byte and be followed only by value bytes.)
  def parse_midi_message(msg)
    pressed = ((msg[2] || 0) >= 64)
    case msg[0]
    when 0x90
      return *xy_for_note(msg[1]), pressed
    when 0xB0
      return *xy_for_controller(msg[1]), pressed
    when 0xF0
      launchpad_id = nil
      if msg.length >= 10 && msg[1] == 0x7E && msg[3] == 0x06
        device_id = msg[2]
        manufacturer = msg[5..7]
        device_type = msg[8..9]
        if manufacturer == NOVATION_MANUFACTURER_ID
          launchpad_id = LAUNCHPAD_DEVICE_ID[device_type] || :unknown_novation_device
        else
          launchpad_id = :unknown_device
        end
      end
      return nil, nil, launchpad_id
    end
    return nil, nil, nil
  end

  # MIDI command to set the bits for the given column and row
  #
  # Rows 0-7 are the square pads, row -1 the round pads on top.
  # Column 8 on rows 0-7 is for the round pads on the side.
  def midi_command_for_position(column, row)
    if row >= 0 && row < 8
      return 0x90, note_for_xy(column, row)
    else
      return 0xB0, controller_for_top_column(column)
    end
  end

  # MIDI note number for the given column and row
  #
  # Note that the top row of round buttons can not be set with
  # note numbers, use `controller_for_top_column` instead.
  def note_for_xy(column, row)
    if @mapping == :xy
      (row * 0x10) + column
    else
      DRUM_RACK_NOTES[row * 9 + column]
    end
  end

  # MIDI controller number for the given top row column
  def controller_for_top_column(column, row = -1)
    0x68 + column
  end

  # Send a MIDI command to the Launchpad
  def send_midi(command, *data)
    if @last_command.nil? || @last_command != command
      @midi_to.puts(command, *data)
      @last_command = command
    else
      @midi_to.puts(*data)
    end
  end

  # Send a device identification inquiry MIDI message.
  # The original Launchpad does not respond to this, but other versions do.
  def send_inquiry
    send_midi(0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7)
  end

  # Yield each pending input message from the Launchpad as an array of bytes.
  def each_incoming_message
    return to_enum(__method__) unless block_given?
    if @midi_from
      @midi_from.gets.each {|msg| yield msg[:data] if msg }
    end
  end

  # Yield each pending action that corresponds to a button press, as
  # `column, row, pressed` where `pressed` is true if the button was
  # pressed down and false if it was released.
  def each_action
    each_incoming_message do |msg|
      column, row, action = parse_midi_message(msg)
      yield column, row, action unless action.nil?
    end
  end

  # Find the output and input devices for a connected Launchpad
  def LaunchpadMIDI.find_output_and_input
    output = UniMIDI::Output.all.find {|dev| dev.name =~ DEVICE_NAME_RE }
    input = UniMIDI::Input.all.find {|dev| dev.name =~ DEVICE_NAME_RE }
    return output, input
  end

  # Instance for an automatically discovered Launchpad, or nil if
  # one isn't found`
  def LaunchpadMIDI.device
    output, input = find_output_and_input
    if input && output
      LaunchpadMIDI.new(output, input)
    else
      nil
    end
  end

end


if __FILE__ == $0
  lp = LaunchpadMIDI.device
  unless lp
    $stderr.puts 'Error: No Launchpad device connected?'
    exit 1
  end

  begin
    lp.reset
    lp.set_duty_cycle(1, 4)
    #lp.set_drum_rack_mapping

    # Iterate through all colours, set the LEDs one by one
    3.downto(0) do |green|
      3.downto(0) do |red|
        -1.upto(7) do |row|
          0.upto((row < 0) ? 7 : 8) do |column|
            lp.set_led_colors(column, row, red, green)
            sleep(0.008)
          end
        end
      end
    end

    # Use offline updates (i.e., information sent to Launchpad
    # only when `update` is called, using rapid updates) and
    # double buffering (i.e., all changes show at once when the
    # buffers are flipped)
    sleep(0.1)
    lp.double_buffer = true
    lp.offline_updates = true

    3.downto(0) do |green|
      3.downto(0) do |red|
        -1.upto(7) do |row|
          0.upto((row < 0) ? 7 : 8) do |column|
            lp.set_led_colors(column, row, red, green)
          end
        end
        lp.update
        lp.flip_buffers
        sleep(0.3)
      end
    end

    # Flashing LEDs by setting up automatic buffer flipping
    lp.double_buffer = false
    lp.flashing = true
    0.upto(7) do |row|
      0.upto(7) do |column|
        if (row % 2) == (column % 2)
          lp.set_led_colors(column, row, 2, 0, true)
        else
          lp.set_led_colors(column, row, 0, 2, false)
        end
      end
    end
    lp.update
    sleep(2.0)

    # Flash manually by flipping buffers
    lp.flashing = false
    lp.double_buffer = true
    lp.set_all_off
    lp.update
    [ true, false ].each do |condition|
      0.upto(7) do |row|
        0.upto(7) do |column|
          if ((row % 2) == (column % 2)) == condition
            lp.set_led_colors(column, row, 3, 0)
          else
            lp.set_led_colors(column, row, 0, 3)
          end
        end
      end
      lp.update
      lp.flip_buffers(false)
    end
    5.times do
      lp.flip_buffers(false)
      sleep(0.5)
    end

  ensure
    lp.reset
  end
end
