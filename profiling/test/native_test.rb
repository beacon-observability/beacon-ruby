# frozen_string_literal: true

# rubocop:disable Minitest/MultipleAssertions, Minitest/ReturnInTestMethod

require_relative 'test_helper'
require 'open3'
require 'rbconfig'

class NativeTest < Minitest::Test
  include ProfileWire

  def native_config
    Beacon::Profiling::Config.new('OTEL_PROFILING_BACKEND' => 'beacon',
                                  'OTEL_PROFILING_MEMORY_ENABLED' => 'true',
                                  'OTEL_PROFILING_HEAP_ENABLED' => 'true',
                                  'OTEL_PROFILING_HEAP_SAMPLE_EVERY' => '1')
  end

  def allocate_retained_strings
    Array.new(10_000) { 'x' * 4096 }
  end

  def retained_size(data)
    profile = decode(Zlib.gunzip(Beacon::Profiling::Pprof.encode(data, 1, 1_000_000_000)))
    strings = profile[6]
    types = profile[1].map { |type| strings[decode(type)[1].first] }
    index = types.index('heap-live-size')
    assert index
    functions = profile[5].to_h do |value|
      function = decode(value)
      [function[1].first || 0, strings[function[2].first || 0]]
    end
    locations = profile[4].to_h do |value|
      location = decode(value)
      [location[1].first, location[4].map { |line| functions[decode(line)[1].first] }]
    end
    profile[2].sum do |value|
      sample = decode(value)
      names = numbers(sample[1]).flat_map { |id| locations.fetch(id, []) }
      names.any? { |name| name.include?('allocate_retained_strings') } ? numbers(sample[2])[index] : 0
    end
  end

  def test_heap_bytes_are_real_live_objects_and_drop_after_gc
    return run_isolated_native unless ENV['BEACON_NATIVE_TEST_CHILD'] == '1'

    native = Beacon::Profiling::Native.new(native_config)
    native.start
    retained = allocate_retained_strings
    GC.start
    sleep 0.15
    before = retained_size(native.snapshot)
    assert_operator before, :>, 0
    assert_equal 10_000, retained.length
    retained.clear
    GC.start(full_mark: true, immediate_sweep: true)
    sleep 0.15
    after = retained_size(native.snapshot)
    assert_operator after, :<, before
    refute defined?(Datadog)
    refute Gem.loaded_specs.key?('datadog')
  ensure
    native&.stop
  end

  def test_native_backend_exports_a_gzip_profile_through_session
    return run_isolated_native unless ENV['BEACON_NATIVE_TEST_CHILD'] == '1'

    Dir.mktmpdir do |dir|
      env = { 'OTEL_PROFILING_ENABLED' => 'true', 'OTEL_PROFILING_BACKEND' => 'beacon',
              'OTEL_PROFILING_MEMORY_ENABLED' => 'true', 'OTEL_PROFILING_HEAP_ENABLED' => 'true',
              'OTEL_PROFILING_HEAP_SAMPLE_EVERY' => '1', 'OTEL_PROFILING_PPROF_PATH' => dir }
      assert Beacon::Profiling.start(env: env)
      retained = allocate_retained_strings
      GC.start
      finish = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.6
      workers = Array.new(2) do
        Thread.new { Math.sqrt(1234) while Process.clock_gettime(Process::CLOCK_MONOTONIC) < finish }
      end
      workers.each(&:join)
      assert Beacon::Profiling.stop
      profiles = Dir[File.join(dir, '*.pprof')].map { |file| decode(Zlib::GzipReader.open(file, &:read)) }
      types = profiles.flat_map { |profile| profile[1].map { |value| profile[6][decode(value)[1].first] } }
      assert_includes types, 'heap-live-samples'
      assert_includes types, 'heap-live-size'
      assert_includes types, 'gvl-wait-time'
      assert_equal 10_000, retained.length
    end
  ensure
    Beacon::Profiling.stop
  end

  def test_native_post_fork_rebuild_preserves_parent
    return run_isolated_native unless ENV['BEACON_NATIVE_TEST_CHILD'] == '1'

    Dir.mktmpdir do |dir|
      env = { 'OTEL_PROFILING_ENABLED' => 'true', 'OTEL_PROFILING_BACKEND' => 'beacon',
              'OTEL_PROFILING_PPROF_PATH' => dir }
      assert Beacon::Profiling.start(env: env)
      child = fork do
        ok = Beacon::Profiling.after_fork(env: env)
        retained = allocate_retained_strings
        GC.start
        sleep 0.15
        ok &&= Beacon::Profiling.stop
        exit!(ok && retained.length == 10_000 ? 0 : 1)
      end
      _, status = Timeout.timeout(10) { Process.wait2(child) }
      assert_predicate status, :success?
      assert Beacon::Profiling.stats[:active]
      assert Beacon::Profiling.stop
      refute_empty Dir[File.join(dir, "ruby-*-#{child}-*.pprof")]
    end
  ensure
    Beacon::Profiling.stop
  end

  private

  def run_isolated_native
    output, status = Open3.capture2e({ 'BEACON_NATIVE_TEST_CHILD' => '1', 'SIMPLECOV_COMMAND_NAME' => "native-#{name}" },
                                     RbConfig.ruby, '-Ilib:test', __FILE__, '--name', name)
    assert_predicate status, :success?, output
  end
end

# rubocop:enable Minitest/MultipleAssertions, Minitest/ReturnInTestMethod
