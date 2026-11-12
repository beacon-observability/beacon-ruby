# frozen_string_literal: true

require 'json'
require 'beacon/profiling'

# @return [Array<String>] synthetic objects retained through the full profile window
def allocate_retained_strings
  Array.new(10_000) { 'heap-example-' * 256 }
end

duration = Float(ENV.fetch('BEACON_PROFILE_EXAMPLE_DURATION', '65'))
abort 'Example duration must be positive and finite' unless duration.finite? && duration.positive?
abort 'Profiling did not start' unless Beacon::Profiling.start
retained = allocate_retained_strings
GC.start
finish = Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration
workers = Array.new(2) do
  Thread.new do
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < finish
      10_000.times { |number| Math.sqrt(number) }
      Thread.pass
    end
  end
end
workers.each(&:join)
GC.start
puts JSON.generate(retained_objects: retained.length, retained_payload_bytes: retained.sum(&:bytesize))
abort 'Profiling shutdown timed out' unless Beacon::Profiling.stop
puts JSON.generate(Beacon::Profiling.stats)
