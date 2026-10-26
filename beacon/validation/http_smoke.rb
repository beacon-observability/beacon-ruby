# frozen_string_literal: true

require 'bundler/setup'
require 'net/http'
require 'opentelemetry-sdk'
require 'opentelemetry-exporter-otlp'
require 'opentelemetry-instrumentation-net_http'

target = URI(ENV.fetch('BEACON_RUBY_SMOKE_URL'))
raise ArgumentError, 'Use an HTTP endpoint for the import smoke check' unless target.is_a?(URI::HTTP)

OpenTelemetry::SDK.configure do |config|
  config.service_name = 'beacon-ruby-import-smoke'
  config.use 'OpenTelemetry::Instrumentation::Net::HTTP'
end

begin
  tracer = OpenTelemetry.tracer_provider.tracer('beacon-ruby-import-smoke')
  tracer.in_span('ruby-import-smoke') do
    response = Net::HTTP.get_response(target)
    raise "Unexpected HTTP status: #{response.code}" unless response.code == '200'
  end

  result = OpenTelemetry.tracer_provider.force_flush(timeout: 10)
  raise 'Trace flush failed' unless result == OpenTelemetry::SDK::Trace::Export::SUCCESS

  puts 'HTTP request and trace flush completed; verify exported spans at the receiver.'
ensure
  OpenTelemetry.tracer_provider.shutdown(timeout: 10)
end
