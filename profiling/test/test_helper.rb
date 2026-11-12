# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  minimum_coverage(ENV['BEACON_NATIVE_TEST_CHILD'] == '1' ? 0 : 85)
end
require 'minitest/autorun'
require 'tmpdir'
require 'zlib'
require 'beacon/profiling'
require 'stackprof'

# Independent protobuf reader for semantic assertions on generated pprof files.
module ProfileWire
  def decode(bytes)
    fields = Hash.new { |hash, key| hash[key] = [] }
    cursor = 0
    read = lambda do
      value = 0
      shift = 0
      loop do
        byte = bytes.getbyte(cursor)
        cursor += 1
        value |= (byte & 127) << shift
        break if byte < 128

        shift += 7
      end
      value
    end
    while cursor < bytes.bytesize
      key = read.call
      if key.nobits?(7)
        fields[key >> 3] << read.call
      else
        length = read.call
        fields[key >> 3] << bytes.byteslice(cursor, length)
        cursor += length
      end
    end
    fields
  end
end

module ProfileWire
  def numbers(values)
    values.flat_map do |value|
      next [value] unless value.is_a?(String)

      decoded = []
      integer = shift = 0
      value.each_byte do |byte|
        integer |= (byte & 127) << shift
        if byte < 128
          decoded << integer
          integer = shift = 0
        else
          shift += 7
        end
      end
      decoded
    end
  end
end
