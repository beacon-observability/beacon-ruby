# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = 'beacon-profiling'
  spec.version = '0.1.0'
  spec.authors = ['Beacon Authors']
  spec.summary = 'Opt-in CPU, wall and heap profiling for Beacon Ruby'
  spec.homepage = 'https://github.com/beacon-observability/beacon-ruby'
  spec.licenses = %w[Apache-2.0 BSD-3-Clause]
  spec.required_ruby_version = '>= 3.3'
  spec.files = Dir['lib/**/*.rb', 'examples/**/*.rb', 'ext/**/*.{c,h,rb}', 'licenses/*', '*.md', 'LICENSE']
  spec.extensions = ['ext/beacon_profiling/extconf.rb']
  spec.add_dependency 'stackprof', '~> 0.2.27'
end
