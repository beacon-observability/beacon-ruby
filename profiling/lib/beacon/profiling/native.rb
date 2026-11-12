# frozen_string_literal: true

module Beacon
  module Profiling
    # Beacon-owned heap and GVL collector, compiled from the bundled C sources.
    class Native
      def initialize(config)
        require 'objspace'
        require 'beacon/profiling/native_ext'
        @recorder = NativeRecorder.create(config.heap_interval, config.max_events, config.max_frames,
                                          config.max_threads, config.heap_enabled, config.heap_size_enabled,
                                          config.gvl_enabled)
      end

      # @return [Array<Integer>] paired wall and monotonic timestamps
      def clock_pair
        NativeRecorder.clock_pair
      end

      # @return [void]
      def start
        @recorder.start
      end

      # @return [void]
      def stop
        @recorder.stop
      end

      # @return [Array<Hash>] sampled live objects, bytes and GVL waits
      def snapshot
        @recorder.snapshot.each do |entry|
          counts = {}
          offset = 0
          while offset < entry[:raw].length
            counts[offset] = 1
            offset += entry[:raw][offset] + 2
          end
          entry[:sample_counts] = counts
        end
      end

      # @return [Hash] bounded collector counters
      def stats
        @recorder.stats
      end

      # @return [void]
      def discard_after_fork
        @recorder.discard_after_fork
      end
    end
  end
end
