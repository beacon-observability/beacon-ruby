# frozen_string_literal: true

require 'uri'
require 'socket'

module Beacon
  module Profiling
    # Validated configuration, shared by sampling and export workers.
    class Config
      attr_reader :modes, :interval, :period, :allocation_interval, :path, :exporter,
                  :endpoint, :headers, :timeout, :shutdown_timeout, :tags, :max_frames,
                  :exception_stride, :max_events, :trace_context, :max_files, :max_threads, :ignore_profiler, :backend, :heap_enabled, :heap_size_enabled, :heap_interval, :gvl_enabled

      def initialize(env)
        @backend = env.fetch('OTEL_PROFILING_BACKEND', enabled?(env['OTEL_PROFILING_HEAP_ENABLED']) ? 'beacon' : 'stackprof')
        raise ArgumentError, 'invalid profiling backend' unless %w[stackprof beacon].include?(@backend)

        @heap_enabled = enabled?(env.fetch('OTEL_PROFILING_HEAP_ENABLED', @backend == 'beacon' ? env.fetch('OTEL_PROFILING_MEMORY_ENABLED', 'false') : 'false'))
        @heap_size_enabled = @heap_enabled && enabled?(env.fetch('OTEL_PROFILING_HEAP_SIZE_ENABLED', 'true'))
        @heap_interval = numeric(env, 'HEAP_SAMPLE_EVERY', 1000, 1..1_000_000).to_i
        @gvl_enabled = @backend == 'beacon' && enabled?(env.fetch('OTEL_PROFILING_GVL_ENABLED', 'true'))
        raise ArgumentError, 'GVL profiling requires the beacon backend' if enabled?(env['OTEL_PROFILING_GVL_ENABLED']) && @backend != 'beacon'
        raise ArgumentError, 'heap size requires heap profiling' if enabled?(env['OTEL_PROFILING_HEAP_SIZE_ENABLED']) && !@heap_enabled
        raise ArgumentError, 'heap profiling requires the beacon backend' if @heap_enabled && @backend != 'beacon'

        @modes = env.fetch('OTEL_PROFILING_TYPES', env.fetch('OTEL_PROFILING_MODE', @backend == 'beacon' ? 'wall,cpu' : 'wall')).split(',').map(&:strip)
        @modes << 'allocations' if enabled?(env['OTEL_PROFILING_MEMORY_ENABLED'])
        @modes = @modes.uniq.map(&:to_sym)
        raise ArgumentError, 'invalid profile types' if @modes.empty? || (@modes - %i[cpu wall allocations]).any?

        @interval = if env.key?('OTEL_PROFILING_SAMPLE_INTERVAL')
                      (numeric(env, 'SAMPLE_INTERVAL', 0.01, 0.001..1) * 1_000_000).round
                    else
                      numeric(env, 'SAMPLING_INTERVAL', 10_000, 1000..1_000_000).to_i
                    end
        @period = numeric(env, 'EXPORT_INTERVAL', env.fetch('OTEL_PROFILING_UPLOAD_INTERVAL', 60), 0.1..300)
        @allocation_interval = numeric(env, 'MEMORY_SAMPLING_INTERVAL', 1000, 1..1_000_000).to_i
        @max_frames = numeric(env, 'MAX_FRAMES', 64, 1..512).to_i
        @max_events = numeric(env, 'MAX_EVENTS', 1000, 1..10_000).to_i
        @max_threads = numeric(env, 'MAX_THREADS', 128, 1..1024).to_i
        @max_files = numeric(env, 'MAX_FILES', 20, 1..10_000).to_i
        @exception_stride = enabled?(env['OTEL_PROFILING_EXCEPTION_ENABLED']) ? numeric(env, 'EXCEPTION_SAMPLING_INTERVAL', 100, 1..1_000_000).to_i : nil
        @ignore_profiler = env.fetch('OTEL_PROFILING_MEMORY_IGNORE_PROFILER', 'true') != 'false'
        @trace_context = env.fetch('OTEL_PROFILING_INCLUDE_TRACE_CONTEXT', 'true') != 'false'
        @path = env.fetch('OTEL_PROFILING_PPROF_PATH', 'otel-profiles')
        @endpoint = env['OTEL_PROFILING_PPROF_UPLOAD_URL'] || env.fetch('OTEL_PROFILING_ENDPOINT', 'http://127.0.0.1:9529/profiling/v1/input')
        @exporter = env.fetch('OTEL_PROFILING_EXPORTER', env.key?('OTEL_PROFILING_PPROF_PATH') && !env.key?('OTEL_PROFILING_PPROF_UPLOAD_URL') ? 'pprof' : 'pprof_http')
        @exporter = { 'file' => 'pprof', 'datakit' => 'pprof_http' }.fetch(@exporter, @exporter)
        raise ArgumentError, 'invalid exporter' unless %w[pprof pprof_http none].include?(@exporter)

        @timeout = numeric(env, 'UPLOAD_TIMEOUT', 5, 0.1..60)
        @shutdown_timeout = numeric(env, 'SHUTDOWN_TIMEOUT', 10, 0.1..60)
        @headers = {}
        if @exporter == 'pprof_http'
          uri = URI(@endpoint)
          raise ArgumentError, 'expected an HTTP(S) upload URL' unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.fragment

          @headers = pairs(env['OTEL_PROFILING_PPROF_HEADERS'], ':')
          reserved_headers = %w[host content-type content-length transfer-encoding connection]
          @headers.each do |key, value|
            raise ArgumentError, 'invalid upload header' unless key.match?(/\A[A-Za-z0-9-]+\z/) && !value.match?(/[\r\n]/)
            raise ArgumentError, 'reserved upload header' if reserved_headers.include?(key.downcase)
          end
        end
        resource = pairs(env['OTEL_RESOURCE_ATTRIBUTES'], '=')
        @tags = { 'language' => 'ruby', 'runtime' => RUBY_ENGINE, 'runtime_version' => RUBY_VERSION,
                  'profiler_version' => '0.1.0', 'host' => resource.fetch('host.name', Socket.gethostname),
                  'service' => env.fetch('OTEL_SERVICE_NAME', resource.fetch('service.name', 'unknown_service:ruby')),
                  'version' => resource['service.version'],
                  'env' => resource['deployment.environment.name'] || resource['deployment.environment'] }.compact
      end

      private

      def enabled?(value)
        %w[true 1 yes on].include?(value.to_s.downcase)
      end

      def numeric(env, suffix, default, range)
        value = Float(env.fetch("OTEL_PROFILING_#{suffix}", default))
        raise ArgumentError, "invalid #{suffix}" unless value.finite? && range.cover?(value)

        value
      end

      def pairs(value, separator)
        value.to_s.split(',').to_h do |pair|
          key, entry = pair.split(separator, 2)
          raise ArgumentError, 'invalid key/value configuration' unless entry && !key.strip.empty?

          [key.strip, URI::DEFAULT_PARSER.unescape(entry.strip)]
        end
      end
    end
  end
end
