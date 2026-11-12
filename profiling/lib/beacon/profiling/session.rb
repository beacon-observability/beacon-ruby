# frozen_string_literal: true

require 'fileutils'
require 'securerandom'
require_relative 'exceptions'
require_relative 'wall'
require_relative 'native'
require_relative 'pprof'
require_relative 'upload'

module Beacon
  module Profiling
    # Owns one native sampler and a bounded, independent export queue.
    class Session
      attr_reader :pid

      def initialize(config)
        @config = config
        @pid = Process.pid
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @stats_mutex = Mutex.new
        @stats = { collected: 0, exported: 0, failed: 0, dropped: 0 }
        @queue = SizedQueue.new(2)
        @index = 0
        @native = Native.new(config) if config.backend == 'beacon'
        @segments = [config.modes.count { |mode| mode != :wall }, 1].max
        @native_modes = config.modes - [:wall]
        @wall = Wall.new(config) if config.modes.include?(:wall)
        @exceptions = Exceptions.new(config) if config.exception_stride
        @upload = Upload.new(config) if config.exporter == 'pprof_http'
      end

      # @return [Boolean] whether sampling started
      def start
        return false if StackProf.running?

        if @native
          # Create Beacon workers before allocation tracking so their stacks are not heap samples.
          @startup = Queue.new
          @export_worker = Thread.new { export_loop if @startup.pop }
          @worker = Thread.new { run if @startup.pop }
          @wall&.start
          @exceptions&.start
          @native.start
          begin_window
          2.times { @startup << true }
        else
          begin_window
          @wall&.start
          @exceptions&.start
          @export_worker = Thread.new { export_loop }
          @worker = Thread.new { run }
        end
        true
      rescue StandardError
        @startup&.close
        @native&.stop
        @wall&.stop
        @exceptions&.stop
        StackProf.stop if @collecting
        @queue.close
        raise
      end

      # @return [Boolean] whether all workers finished within the shutdown budget
      def stop
        return false unless Process.pid == @pid

        deadline = monotonic + (@config.shutdown_timeout * 1_000_000_000).to_i
        @mutex.synchronize do
          @stopping = true
          @condition.broadcast
        end
        [@worker, @export_worker].compact.all? do |worker|
          remaining = (deadline - monotonic) / 1_000_000_000.0
          remaining.positive? && worker.join(remaining)
        end
      end

      # @return [Hash] counters and worker state, without payloads or credentials
      def stats
        @stats_mutex.synchronize { @stats.dup.merge(backend: @config.backend, native: @native&.stats, active: !!alive?, running: !!@worker&.alive?, pending: @queue.length) }
      end

      # @return [Boolean] whether either worker still owns session resources
      def alive?
        @worker&.alive? || @export_worker&.alive?
      end

      # Clears only state inherited from this session in a forked child.
      # @return [void]
      def discard_after_fork
        @native&.discard_after_fork
        @exceptions&.stop
        StackProf.stop if @collecting
        StackProf.results if @collecting
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      end

      def increment(key)
        @stats_mutex.synchronize { @stats[key] += 1 }
      end

      def begin_window
        @mode = @native_modes[@index % @native_modes.length] unless @native_modes.empty?
        @index += 1
        if @native
          @started, @monotonic = @native.clock_pair
        else
          @started = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
          @monotonic = monotonic
        end
        return unless @mode

        interval = @mode == :allocations ? @config.allocation_interval : @config.interval
        mode = @mode == :allocations ? :object : @mode
        raise 'StackProf already running' unless StackProf.start(mode: mode, interval: interval, raw: true)

        @collecting = true
      end

      def snapshot
        if @collecting
          StackProf.stop
          @collecting = false
          data = StackProf.results
        end
        duration = monotonic - @monotonic
        profiles = [data, @wall&.snapshot, @exceptions&.snapshot, *@native&.snapshot].compact.select do |entry|
          # An empty final heap snapshot clears earlier gauges in the export window.
          entry[:samples].positive? || entry[:mode] == :heap_objects || entry[:mode] == :heap_size
        end
        profiles.each do |entry|
          entry[:started] = @started
          entry[:duration] = duration
        end
        [profiles, @started, duration]
      end

      def run
        Thread.current[:beacon_profiling_internal] = true
        entries = []
        started = @started
        window_start = @monotonic
        segments = 0
        loop do
          stopping = @mutex.synchronize do
            @condition.wait(@mutex, @config.period / @segments) unless @stopping
            @stopping
          end
          @native&.stop if stopping
          @wall&.stop if stopping
          @exceptions&.stop if stopping
          chunk = snapshot
          entries.concat(chunk.first)
          segments += 1
          duration = monotonic - window_start
          begin_window unless stopping
          if segments >= @segments || stopping
            unless entries.empty?
              increment(:collected)
              enqueue([entries, started, duration])
            end
            entries = []
            segments = 0
            started = @started
            window_start = @monotonic
          end
          break if stopping
        end
      rescue StandardError => e
        increment(:failed)
        warn "Beacon profiling stopped (#{e.class})"
      ensure
        @native&.stop
        @wall&.stop
        @exceptions&.stop
        StackProf.stop if @collecting
        @collecting = false
        @queue.close
      end

      def enqueue(batch)
        @queue.push(batch, true)
      rescue ThreadError
        increment(:dropped)
      end

      def export_loop
        Thread.current[:beacon_profiling_internal] = true
        while (batch = @queue.pop)
          profiles, started, duration = batch
          if defined?(OpenTelemetry::Common::Utilities)
            OpenTelemetry::Common::Utilities.untraced do
              export_batch(profiles, started, duration)
            end
          else
            export_batch(profiles, started, duration)
          end
        end
      end

      def export_batch(profiles, started, duration)
        if @upload
          export(profiles, started, duration)
        else
          profiles.each { |data| export(data, data.fetch(:started, started), data.fetch(:duration, duration)) }
        end
      end

      def export(data, started, duration)
        return if @config.exporter == 'none'

        profile = Pprof.encode(data, started, duration, max_frames: @config.max_frames, ignore_profiler: @config.ignore_profiler)
        return unless profile

        if @upload
          @upload.export(profile, :auto, started, duration)
        else
          save(profile, data[:mode])
        end
        increment(:exported)
      rescue StandardError => e
        increment(:failed)
        detail = e.message.match?(/\Aprofile upload rejected: HTTP \d{3}\z/) ? ": #{e.message}" : ''
        warn "Beacon profile export failed (#{e.class}#{detail})"
      end

      def save(profile, mode)
        FileUtils.mkdir_p(@config.path, mode: 0o700)
        filename = File.join(@config.path, "ruby-#{mode}-#{@pid}-#{SecureRandom.hex(8)}.pprof")
        File.open(filename, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(profile) }
        files = Dir[File.join(@config.path, "ruby-*-#{@pid}-*.pprof")].sort_by { |path| File.mtime(path) }
        files.first([files.length - @config.max_files, 0].max).each { |path| File.unlink(path) }
      end
    end
  end
end
