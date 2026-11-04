# frozen_string_literal: true

require 'bundler/setup'
require 'rack/mock'
require 'rack/request'
require 'opentelemetry/sdk'
require 'opentelemetry/sdk/logs'
require 'opentelemetry-exporter-otlp-logs'
require 'beacon/security'

ENV['OTEL_TRACES_EXPORTER'] ||= 'none'
ENV['OTEL_METRICS_EXPORTER'] ||= 'none'
ENV['OTEL_LOGS_EXPORTER'] ||= 'console'
OpenTelemetry::SDK.configure do |config|
  config.service_name = 'beacon-ruby-security-example'
end
runtime = Beacon::Security.start
tracer = OpenTelemetry.tracer_provider.tracer('beacon-security-example')
app = Beacon::Security::Middleware.new(lambda { |env|
  path = Rack::Request.new(env).params.fetch('path')
  File.read(path)
  [200, {}, []]
}, runtime: runtime)
tracer.in_span('example-request', kind: :server) do
  app.call(Rack::MockRequest.env_for('/?path=%2Fdev%2Fnull'))
end
runtime.collect_inventory
runtime.force_flush
runtime.shutdown
OpenTelemetry.logger_provider.shutdown
OpenTelemetry.tracer_provider.shutdown
