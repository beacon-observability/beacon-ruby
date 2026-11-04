# frozen_string_literal: true

require 'etc'
require 'fileutils'
module Beacon
  module Security
    # Owns a process-local serial inventory worker, but never owns OTel shutdown.
    class Runtime
      MAX_EVENT_BYTES = 65_536
      MAX_DEPENDENCIES = 10_000
      attr_reader :application_id, :instance_id

      # @param configuration [Configuration] environment binding
      # @param logger [OpenTelemetry::Logs::Logger, nil] injected OTel logger
      # @param resource [Hash, nil] same resource attributes used by the host SDK
      def initialize(configuration: Configuration.new, logger: nil, resource: nil)
        @configuration = configuration
        @pid = Process.pid
        @instance_id = SecureRandom.uuid
        @logger = logger || OpenTelemetry::Internal.logger_provider.logger(name: 'io.beacon.security', version: VERSION)
        resource ||= if OpenTelemetry.tracer_provider.respond_to?(:resource)
                       OpenTelemetry.tracer_provider.resource.attribute_enumerator.to_h
                     else
                       {}
                     end
        @application_id = Fingerprint.application_id(resource)
        @mutex = Mutex.new
        @inventory_mutex = Mutex.new
        @queue = SizedQueue.new(1024)
        @condition = ConditionVariable.new
        @stopped = false
        @last_observed = nil
      end

      # A forked child must create its own identity and workers.
      def enabled?
        @configuration.enabled && @pid == Process.pid && !@stopped
      end

      # Launch only the workers allowed by the opt-in configuration.
      def start
        return self unless enabled?
        return self if @export_worker&.alive?

        @export_worker = Thread.new do
          while (item = @queue.pop)
            if item.is_a?(Queue)
              item << true
            else
              deliver(item)
            end
          end
        end
        return self unless @configuration.sbom_enabled

        @worker = Thread.new do
          loop do
            collect_inventory
            stop = @mutex.synchronize do
              @condition.wait(@mutex, @configuration.refresh_seconds) unless @stopped
              @stopped
            end
            break if stop
          end
        end
        self
      end

      # Bounded join; a broken host logger cannot indefinitely block shutdown.
      def shutdown
        @mutex.synchronize do
          @stopped = true
          @condition.broadcast
        end
        @queue.close
        @worker&.join(1) unless @worker == Thread.current
        @export_worker&.join(1) unless @export_worker == Thread.current
        nil
      end

      # Internal adapter entry point; metadata must describe code, never values.
      def observe(rule, value, **sink)
        request = Security.current_request
        request&.observe(rule, value, **sink) if enabled?
      rescue StandardError
        nil
      end

      # Shared wire identity for both supported v2 event families.
      def envelope(name, source)
        { 'schema_version' => SCHEMA_VERSION, 'event_name' => name, 'source' => source,
          'instance_id' => @instance_id, 'observed_at' => Time.now.utc.iso8601(9) }
      end

      # Nonblocking bounded handoff; full queues drop new records without replay.
      def emit(event)
        return unless enabled?

        @queue.push(event, true)
      rescue ThreadError, ClosedQueueError
        nil
      end

      # Wait at most one second for preceding Security records, not backend receipt.
      def force_flush
        barrier = Queue.new
        @queue.push(barrier, true)
        barrier.pop(timeout: 1) == true
      rescue ThreadError, ClosedQueueError
        false
      end

      # Serialize only on the worker and isolate host logger/filesystem failures.
      def deliver(event)
        json = JSON.generate(event)
        if json.bytesize > MAX_EVENT_BYTES && event['event_name'] == 'beacon.security.finding'
          event = event.except('sources', 'propagation', 'ranges', 'stack')
          event.merge!('evidence_sampled' => false, 'evidence_sample_reason' => 'record_byte_limit', 'truncated' => true, 'truncation_reason' => 'record_byte_limit')
          json = JSON.generate(event)
        end
        return if json.bytesize > MAX_EVENT_BYTES

        @logger.on_emit(severity_number: 9, severity_text: 'INFO', body: json, event_name: event['event_name'],
                        attributes: { 'event.name' => event['event_name'], 'source' => event['source'] },
                        trace_id: event['trace_id'] && [event['trace_id']].pack('H*'),
                        span_id: (event['current_span_id'] || event['server_span_id'])&.then { |id| [id].pack('H*') },
                        timestamp: Time.iso8601(event.fetch('observed_at')))
        write_diagnostics(json, event) if @configuration.local_output
      rescue StandardError
        nil
      end

      # Failed scans emit nothing. Successful empty scans are valid replacements.
      def collect_inventory
        return unless enabled? && @configuration.sbom_enabled

        @inventory_mutex.synchronize do
          timing = process_timing
          return if Gem.loaded_specs.size > MAX_DEPENDENCIES

          dependencies = Gem.loaded_specs.values.map { |spec| { 'name' => spec.name, 'version' => spec.version.to_s } }.sort_by { |dep| dep['name'] }
          return if dependencies.size > MAX_DEPENDENCIES

          now = Time.now.utc
          now = @last_observed + Rational(1, 1_000_000_000) if @last_observed && now <= @last_observed
          @last_observed = now
          base = envelope('beacon.security.sbom.inventory', 'beacon_security_sbom').merge(timing).merge('observed_at' => now.iso8601(9))
          parts = inventory_parts(base, dependencies)
          parts.each { |event| emit(event) }
        end
      rescue StandardError
        nil
      end

      private

      def process_timing
        # Linux kernel process start ticks, independent of gem/framework initialization.
        ticks = File.read('/proc/self/stat').rpartition(') ').last.split[19].to_i
        boot_now = Process.clock_gettime(Process::CLOCK_BOOTTIME)
        uptime = boot_now - ticks.fdiv(Etc.sysconf(Etc::SC_CLK_TCK))
        @started_at ||= (Time.now.utc - uptime).iso8601(9)
        { 'started_at' => @started_at, 'uptime_ms' => [(uptime * 1000).to_i, 0].max }
      end

      def inventory_parts(base, dependencies)
        whole = base.merge('dependencies' => dependencies)
        return [whole] if JSON.generate(whole).bytesize <= MAX_EVENT_BYTES

        groups = [[]]
        dependencies.each do |dependency|
          trial = base.merge('dependencies' => groups.last + [dependency], 'part_index' => MAX_DEPENDENCIES, 'part_count' => MAX_DEPENDENCIES)
          if JSON.generate(trial).bytesize > MAX_EVENT_BYTES
            raise RangeError, 'dependency exceeds record budget' if groups.last.empty?

            groups << []
          end
          groups.last << dependency
        end
        groups.each_with_index.map { |group, index| base.merge('dependencies' => group, 'part_index' => index, 'part_count' => groups.size) }
      end

      def write_diagnostics(json, event)
        FileUtils.mkdir_p(@configuration.output, mode: 0o700)
        path = File.join(@configuration.output, "#{@instance_id}-#{event['source']}.json")
        File.write(path, json, mode: 'w', perm: 0o600)
        evidence = @configuration.evidence_file
        File.open(evidence, 'a', 0o600) { |file| file.puts(json) } if evidence && event['source'] == 'beacon_security'
      end
    end
  end
end
