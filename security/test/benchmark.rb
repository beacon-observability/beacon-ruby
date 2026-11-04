# frozen_string_literal: true

require 'bundler/setup'
require 'benchmark'
require 'rack/mock'
require 'beacon/security'

iterations = Integer(ENV.fetch('BEACON_BENCH_ITERATIONS', '10000'))
env = Rack::MockRequest.env_for('/?name=benchmark-private-value')
app = ->(_env) { [200, {}, []] }
disabled = Beacon::Security::Runtime.new(configuration: Beacon::Security::Configuration.new({})).start
enabled = Beacon::Security::Runtime.new(configuration: Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_ENABLED' => 'false')).start
without_security = Beacon::Security::Middleware.new(app, runtime: disabled)
with_security = Beacon::Security::Middleware.new(app, runtime: enabled)
with_finding = Beacon::Security::Middleware.new(lambda { |_env|
  enabled.observe('sql_injection', 'select benchmark-private-value', function: 'DB.query', role: 'sql_template')
  [200, {}, []]
}, runtime: enabled)
results = { 'iterations' => iterations, 'ruby' => RUBY_DESCRIPTION }
{ 'plain' => app, 'disabled' => without_security, 'enabled_no_sink' => with_security, 'enabled_matching_sink' => with_finding }.each do |name, target|
  runs = Array.new(3) { Benchmark.realtime { iterations.times { target.call(env) } } }
  results["#{name}_us_per_request"] = (runs.sort[1] * 1_000_000 / iterations).round(3)
end
puts JSON.pretty_generate(results)
enabled.shutdown
disabled.shutdown
