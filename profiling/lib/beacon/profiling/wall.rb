# frozen_string_literal: true

module Beacon
  module Profiling
    # Bounded Ruby-thread wall sampling, independent of the native CPU sampler.
    class Wall
      def initialize(config)
        @config = config
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @stacks = {}
      end

      # @return [void]
      def start
        @worker = Thread.new do
          Thread.current[:beacon_profiling_internal] = true
          loop do
            stopping = @mutex.synchronize do
              @condition.wait(@mutex, @config.interval / 1_000_000.0) unless @stopping
              @stopping
            end
            break if stopping

            capture
          end
        end
      end

      # @return [void]
      def stop
        @mutex.synchronize do
          @stopping = true
          @condition.broadcast
        end
        @worker&.join
      end

      # @return [Hash] detached profile with per-thread labels
      def snapshot
        stacks = @mutex.synchronize do
          previous = @stacks
          @stacks = {}
          previous
        end
        frames = {}
        raw = []
        labels = {}
        stacks.each do |(thread_id, stack), count|
          labels[raw.length] = { 'thread id' => thread_id.to_s }
          ids = stack.reverse.map do |name, file, line|
            id = frames.length + 1
            frames[id] = { name: name, file: file, line: line }
            id
          end
          raw.push(ids.length, *ids, count)
        end
        { mode: :wall, interval: @config.interval, samples: stacks.values.sum,
          frames: frames, raw: raw, labels: labels }
      end

      private

      def capture
        Thread.list.reject { |thread| thread[:beacon_profiling_internal] || thread.name == 'Timeout stdlib thread' }.first(@config.max_threads).each do |thread|
          locations = thread.backtrace_locations(0, @config.max_frames)
          next unless locations

          stack = locations.map { |loc| [loc.base_label, loc.path, loc.lineno] }
          key = [thread.object_id, stack]
          @mutex.synchronize do
            next if @stacks.length >= @config.max_events && !@stacks.key?(key)

            @stacks[key] = @stacks.fetch(key, 0) + 1
          end
        end
      end
    end
  end
end
