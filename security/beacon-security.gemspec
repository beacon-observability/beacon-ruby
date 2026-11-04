# frozen_string_literal: true

require_relative 'lib/beacon/security/version'
Gem::Specification.new do |spec|
  spec.name = 'beacon-security'
  spec.version = Beacon::Security::VERSION
  spec.authors = ['Beacon Authors']
  spec.summary = 'Opt-in Beacon Security runtime observations for Ruby'
  spec.homepage = 'https://github.com/beacon-observability/beacon-ruby'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.3'
  spec.files = Dir['lib/**/*.rb', '*.md', 'LICENSE', 'contract.json']
  spec.add_dependency 'opentelemetry-api', '~> 1.7'
  spec.add_dependency 'opentelemetry-logs-api', '~> 0.7'
end
