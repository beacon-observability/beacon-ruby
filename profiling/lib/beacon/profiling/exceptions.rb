# frozen_string_literal: true

module Beacon
  module Profiling
    # Bounded exception samples; never retains exceptions, messages or locals.
    class Exceptions
      def initialize(config)
        @config = config
        @pid = Process.pid
        @mutex = Mutex.new
        @events = []
        @seen = 0
        @hook = TracePoint.new(:raise) { |event| capture(event) }
      end

      # @return [void]
      def start
        @hook.enable
      end

      # @return [void]
      def stop
        @hook.disable
      end

      # @return [Hash] detached exception profile
      def snapshot
        events = @mutex.synchronize do
          previous = @events
          @events = []
          previous
        end
        frames = {}
        raw = []
        labels = {}
        events.each do |stack, context|
          labels[raw.length] = context
          ids = stack.reverse.map do |name, file, line|
            id = frames.length + 1
            frames[id] = { name: name, file: file, line: line }
            id
          end
          raw.push(ids.length, *ids, 1)
        end
        { mode: :exceptions, interval: @config.exception_stride, samples: events.length,
          frames: frames, raw: raw, labels: labels }
      end

      private

      def capture(event)
        return if Process.pid != @pid || Thread.current[:beacon_profiling_internal]

        @seen += 1
        return unless (@seen % @config.exception_stride).zero?

        @mutex.synchronize do
          return if @events.length >= @config.max_events

          stack = (event.raised_exception.backtrace_locations || []).first(@config.max_frames).map { |loc| [loc.base_label, loc.path, loc.lineno] }
          labels = { 'exception type' => event.raised_exception.class.name.to_s[0, 256],
                     'thread id' => Thread.current.object_id.to_s }
          if @config.trace_context && defined?(OpenTelemetry::Trace)
            context = OpenTelemetry::Trace.current_span.context
            if context.valid?
              labels['trace id'] = context.hex_trace_id
              labels['span id'] = context.hex_span_id
            end
          end
          @events << [stack, labels]
        end
      rescue StandardError
        # A collector callback must never change application exception handling.
        nil
      end
    end
  end
end
