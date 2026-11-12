# frozen_string_literal: true

require 'json'
require 'beacon/profiling'
duration = Float(ENV.fetch('BEACON_PROFILE_EXAMPLE_DURATION', '125'))
abort 'Example duration must be positive and finite' unless duration.finite? && duration.positive?
abort 'Profiling did not start' unless Beacon::Profiling.start

finish = Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration
while Process.clock_gettime(Process::CLOCK_MONOTONIC) < finish
  1000.times do
    Object.new
    Math.sqrt(1234)
  end
  begin
    raise ArgumentError, 'synthetic private message'
  rescue ArgumentError
    nil
  end
  sleep 0.001
end
abort 'Profiling shutdown timed out' unless Beacon::Profiling.stop
puts JSON.generate(Beacon::Profiling.stats)
