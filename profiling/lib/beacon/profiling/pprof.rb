# frozen_string_literal: true

require 'zlib'
require 'stringio'

module Beacon
  module Profiling
    # Encodes the subset of perftools.profiles used by StackProf samples.
    class Pprof
      # @return [String] gzip-compressed pprof protobuf
      def self.encode(data, started, duration, max_frames: 64, ignore_profiler: true)
        new.encode(data, started, duration, max_frames: max_frames, ignore_profiler: ignore_profiler)
      end

      # @return [String] gzip-compressed pprof protobuf
      def encode(data, started, duration, max_frames: 64, ignore_profiler: true)
        @strings = { '' => 0 }
        profiles = data.is_a?(Array) ? data : [data]
        # Heap snapshots are gauges; preserve only the last snapshot in a window.
        gauges = %i[heap_objects heap_size]
        latest = {}
        profiles.each_with_index { |entry, index| latest[entry[:mode]] = index if gauges.include?(entry[:mode]) }
        profiles = profiles.each_with_index.filter_map do |entry, index|
          entry unless gauges.include?(entry[:mode]) && latest[entry[:mode]] != index
        end
        profiles.reject! { |entry| (entry[:raw] || []).empty? }
        names = { cpu: 'cpu-time', wall: 'wall-time', object: 'alloc-samples', exceptions: 'exception-samples',
                  heap_objects: 'heap-live-samples', heap_size: 'heap-live-size', gvl_wait: 'gvl-wait-time', timeline: 'timeline' }
        microsecond_modes = %i[cpu wall]
        timed_modes = %i[cpu wall gvl_wait timeline]
        modes = profiles.map { |entry| entry[:mode] }.uniq
        result = bytes(1, number(1, string('samples')) + number(2, string('count')))
        modes.each do |mode|
          unit = if timed_modes.include?(mode)
                   'nanoseconds'
                 else
                   (mode == :heap_size ? 'bytes' : 'count')
                 end
          result << bytes(1, number(1, string(names.fetch(mode))) + number(2, string(unit)))
        end
        if modes.length == 1
          period = profiles.first[:interval] * (microsecond_modes.include?(modes.first) ? 1000 : 1)
          type = number(1, string(names.fetch(modes.first))) + number(2, string(if timed_modes.include?(modes.first)
                                                                                  'nanoseconds'
                                                                                else
                                                                                  (modes.first == :heap_size ? 'bytes' : 'count')
                                                                                end))
          result << bytes(11, type) << number(12, period)
        end
        result << number(9, started) << number(10, duration)
        next_id = 0
        emitted = 0
        internal_path = "#{File.expand_path(__dir__)}/"
        profiles.each do |entry|
          ids = {}
          entry[:frames].each do |address, frame|
            id = ids[address] = (next_id += 1)
            function = number(1, id) + number(2, string(frame[:name])) + number(4, string(frame[:file]))
            result << bytes(5, function)
            line = number(1, id) + number(2, [frame[:line].to_i, 0].max)
            result << bytes(4, number(1, id) + bytes(4, line))
          end
          raw = entry[:raw] || []
          offset = 0
          period = entry[:interval] * (microsecond_modes.include?(entry[:mode]) ? 1000 : 1)
          while offset < raw.length
            length = raw[offset]
            # Native and thread collectors store roots first; pprof requires leaves first.
            stack = raw.slice(offset + 1, length).reverse
            unless ignore_profiler && stack.any? { |address| entry[:frames].fetch(address)[:file].to_s.start_with?(internal_path) }
              count = raw[offset + length + 1]
              sample = stack.first(max_frames).map { |address| number(1, ids.fetch(address)) }.join
              values = Array.new(modes.length + 1, 0)
              values[0] = entry.fetch(:sample_counts, {}).fetch(offset, count)
              values[modes.index(entry[:mode]) + 1] = count * period
              values.each { |value| sample << number(2, value) }
              (entry.fetch(:labels, {})[offset] || {}).each do |key, value|
                label = number(1, string(key))
                label << if value.is_a?(Integer)
                           number(3, value) + number(4, string('nanoseconds'))
                         else
                           number(2, string(value))
                         end
                sample << bytes(3, label)
              end
              result << bytes(2, sample)
              emitted += 1
            end
            offset += length + 2
          end
        end
        return if emitted.zero?

        @strings.each_key { |value| result << bytes(6, value) }
        output = StringIO.new
        gzip = Zlib::GzipWriter.new(output)
        gzip.write(result)
        gzip.close
        output.string
      end

      private

      def string(value)
        value = value.to_s
        @strings[value] ||= @strings.length
      end

      def varint(value)
        result = +''.b
        while value >= 128
          result << ((value & 127) | 128)
          value >>= 7
        end
        result << value
      end

      def number(field, value)
        varint(field << 3) + varint(value)
      end

      def bytes(field, value)
        value = value.b
        varint((field << 3) | 2) + varint(value.bytesize) + value
      end
    end
  end
end
