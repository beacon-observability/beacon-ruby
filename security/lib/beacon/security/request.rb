# frozen_string_literal: true

module Beacon
  module Security
    # Request-local, bounded approximate matching. Raw values never leave this object.
    class Request
      MAX_SOURCES = 64
      MAX_SOURCE_BYTES = 4096
      MAX_INPUT_BYTES = 65_536
      MAX_FINDINGS = 128
      MAX_OBSERVATIONS = 1024
      GAPS = %w[substring_matching_only no_body_capture no_async_propagation no_streaming_body no_sanitizer_analysis].freeze
      EXCLUDED_HEADERS = %w[HTTP_AUTHORIZATION HTTP_PROXY_AUTHORIZATION HTTP_COOKIE].freeze
      INTERNAL_PATHS = [__dir__, "#{__dir__}.rb", RbConfig::CONFIG['rubylibdir'], *Gem.path].freeze
      attr_reader :findings

      def initialize(runtime, env)
        @runtime = runtime
        @env = env
        @sources = []
        @findings = {}
        @limited = false
        @source_bytes = 0
        @observations = 0
        @server_context = OpenTelemetry::Trace.current_span.context
        collect_sources
      end

      # Correlate values without exporting their content or asserting exploitability.
      def observe(rule, value, **sink)
        return unless value.is_a?(String)

        @observations += 1
        if @observations > MAX_OBSERVATIONS || value.bytesize > MAX_INPUT_BYTES
          @limited = true
          return
        end
        bytes = value.b
        matches = @sources.select { |source| bytes.include?(source[:value]) }
        return if matches.empty?

        location = sink.delete(:location) || application_location
        sink = sink.transform_keys(&:to_s).merge('location' => location)
        signatures = matches.map { |s| "#{s[:metadata]['type']}|#{s[:metadata]['name']}" }
        id = Fingerprint.finding(application_id: @runtime.application_id, language: 'ruby', rule: rule, sink: sink, source_signatures: signatures)
        return if @findings.key?(id)

        if @findings.size >= MAX_FINDINGS
          @limited = true
          return
        end
        event = @runtime.envelope('beacon.security.finding', 'beacon_security').merge(
          'finding_id' => id, 'occurrence_id' => SecureRandom.uuid, 'fingerprint_version' => FINGERPRINT_VERSION,
          'rule' => rule, 'sink' => sink, 'attack_evidence' => { 'status' => 'unknown', 'reason' => 'approximate_flow_without_policy' },
          'evidence_sampled' => true, 'collection_complete' => false, 'precision' => 'approximate',
          'coverage_gaps' => GAPS.dup, 'sources' => matches.map { |s| s[:metadata] }
        )
        if @server_context.valid?
          event['trace_id'] = @server_context.hex_trace_id
          event['server_span_id'] = @server_context.hex_span_id
          current = OpenTelemetry::Trace.current_span.context
          event['current_span_id'] = current.hex_span_id if current.valid? && current.span_id != @server_context.span_id
        end
        @findings[id] = event
      end

      # Attach final request outcome and discard all retained raw values.
      def finish(status: nil, error: nil)
        request = {}
        method = @env['REQUEST_METHOD']
        request['method'] = method if %w[GET HEAD POST PUT DELETE CONNECT OPTIONS TRACE PATCH].include?(method)
        route = @env['beacon.security.route']
        request['route'] = route if route.is_a?(String) && route.bytesize <= 1024
        request['status_code'] = status if status.is_a?(Integer)
        request['error_type'] = error.class.name if error&.class&.name
        @findings.each_value do |event|
          event['request'] = request unless request.empty?
          if @limited
            event['truncated'] = true
            event['truncation_reason'] = 'request_budget'
            event['coverage_gaps'] << 'request_budget'
          end
          @runtime.emit(event)
        end
      ensure
        @sources.clear
        @findings.clear
      end

      private

      def collect_sources
        query = @env.fetch('QUERY_STRING', '')
        if query.bytesize > MAX_INPUT_BYTES
          @limited = true
        elsif defined?(::Rack::Utils)
          ::Rack::Utils.parse_query(query).each do |name, values|
            Array(values).each { |value| add_source('http.request.parameter', name, value, 'rack.query') }
          end
        end
        @env.each do |key, value|
          next unless key.start_with?('HTTP_')
          next if EXCLUDED_HEADERS.include?(key)

          add_source('http.request.header', key.delete_prefix('HTTP_').downcase.tr('_', '-'), value, 'rack.header')
        end
      rescue StandardError
        @limited = true
      end

      def add_source(type, name, value, location)
        return unless value.is_a?(String) && !value.empty?

        if @sources.size >= MAX_SOURCES || value.bytesize > MAX_SOURCE_BYTES || @source_bytes + value.bytesize > MAX_INPUT_BYTES || name.bytesize > 256
          @limited = true
          return
        end
        @source_bytes += value.bytesize
        metadata = { 'id' => "source-#{@sources.size}", 'type' => type, 'name' => Fingerprint.text(name), 'location' => location,
                     'value_type' => 'string', 'value_length' => value.length }
        @sources << { value: value.b, metadata: metadata }
      end

      def application_location
        frame = caller_locations(1, 64).find { |entry| INTERNAL_PATHS.none? { |path| entry.path.start_with?(path) } }
        frame ? "#{frame.path}:#{frame.lineno}" : 'unknown'
      end
    end
  end
end
