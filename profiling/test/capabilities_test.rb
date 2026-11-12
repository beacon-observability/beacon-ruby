# frozen_string_literal: true

# rubocop:disable Minitest/MultipleAssertions

require 'English'
require_relative 'test_helper'
require 'opentelemetry-api'

class CapabilitiesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @env = { 'OTEL_PROFILING_ENABLED' => 'true', 'OTEL_PROFILING_PPROF_PATH' => @dir,
             'OTEL_PROFILING_EXPORT_INTERVAL' => '0.1' }
  end

  def teardown
    Beacon::Profiling.stop
    FileUtils.remove_entry(@dir)
  end

  def wait_for
    finish = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4
    until yield
      raise 'timed out waiting for profile' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > finish

      sleep 0.01
    end
  end

  def allocate_objects
    10_000.times { Object.new }
  end

  def test_rotating_wall_cpu_and_allocation_profiles_have_distinct_units
    @env.merge!('OTEL_PROFILING_TYPES' => 'wall,cpu', 'OTEL_PROFILING_MEMORY_ENABLED' => 'true',
                'OTEL_PROFILING_MEMORY_SAMPLING_INTERVAL' => '10')
    assert Beacon::Profiling.start(env: @env)
    wait_for do
      allocate_objects
      %w[wall cpu object].all? { |mode| Dir[File.join(@dir, "ruby-#{mode}-*.pprof")].any? }
    end
    Beacon::Profiling.stop
    object = Zlib::GzipReader.open(Dir[File.join(@dir, 'ruby-object-*')].first, &:read)
    assert_includes object, 'alloc-samples'
    refute_includes object, 'nanoseconds'
    assert_operator Beacon::Profiling.stats[:exported], :>=, 3
  end

  def test_exception_class_and_thread_are_recorded_without_message
    @env['OTEL_PROFILING_EXCEPTION_ENABLED'] = 'true'
    @env['OTEL_PROFILING_EXCEPTION_SAMPLING_INTERVAL'] = '1'
    assert Beacon::Profiling.start(env: @env)
    5.times do
      raise ArgumentError, 'private-password-never-export'
    rescue ArgumentError
      nil
    end
    Beacon::Profiling.stop
    profile = Zlib::GzipReader.open(Dir[File.join(@dir, 'ruby-exceptions-*')].first, &:read)
    assert_includes profile, 'exception-samples'
    assert_includes profile, 'ArgumentError'
    assert_includes profile, 'thread id'
    refute_includes profile, 'private-password-never-export'
  end

  def test_exception_buffer_is_bounded
    config = Beacon::Profiling::Config.new(@env.merge('OTEL_PROFILING_EXCEPTION_ENABLED' => 'true',
                                                      'OTEL_PROFILING_EXCEPTION_SAMPLING_INTERVAL' => '1',
                                                      'OTEL_PROFILING_MAX_EVENTS' => '2'))
    collector = Beacon::Profiling::Exceptions.new(config)
    collector.start
    10.times do
      raise 'synthetic'
    rescue RuntimeError
      nil
    end
    collector.stop
    assert_equal 2, collector.snapshot[:samples]
    assert_equal 0, collector.snapshot[:samples]
  ensure
    collector&.stop
  end

  def test_resource_metadata_header_and_alias_configuration
    config = Beacon::Profiling::Config.new(@env.merge('OTEL_PROFILING_EXPORTER' => 'datakit',
                                                      'OTEL_PROFILING_SAMPLE_INTERVAL' => '0.02',
                                                      'OTEL_SERVICE_NAME' => 'checkout',
                                                      'OTEL_RESOURCE_ATTRIBUTES' => 'service.version=2,deployment.environment.name=test,host.name=demo',
                                                      'OTEL_PROFILING_PPROF_HEADERS' => 'Authorization:Bearer%20synthetic'))
    assert_equal 'pprof_http', config.exporter
    assert_equal 20_000, config.interval
    assert_equal '2', config.tags['version']
    assert_equal 'test', config.tags['env']
    assert_equal 'demo', config.tags['host']
    assert_equal 'checkout', config.tags['service']
    assert_equal 'Bearer synthetic', config.headers['Authorization']
    assert_raises(ArgumentError) do
      Beacon::Profiling::Config.new(@env.merge('OTEL_PROFILING_EXPORTER' => 'datakit', 'OTEL_PROFILING_PPROF_HEADERS' => 'X-Test:bad%0Aheader'))
    end
    assert_raises(ArgumentError) do
      Beacon::Profiling::Config.new(@env.merge('OTEL_PROFILING_EXPORTER' => 'datakit', 'OTEL_PROFILING_PPROF_HEADERS' => 'Content-Length:2'))
    end
  end

  def test_file_retention
    @env['OTEL_PROFILING_MAX_FILES'] = '2'
    assert Beacon::Profiling.start(env: @env)
    wait_for { Beacon::Profiling.stats[:exported] >= 4 }
    Beacon::Profiling.stop
    assert_equal 2, Dir[File.join(@dir, '*.pprof')].length
  end

  def test_preloaded_fork_reinitializes_child_without_stopping_parent
    @env['OTEL_PROFILING_TYPES'] = 'wall,cpu'
    assert Beacon::Profiling.start(env: @env)
    child = fork do
      ok = Beacon::Profiling.after_fork(env: @env)
      sleep 0.15
      ok &&= Beacon::Profiling.stop
      exit!(ok ? 0 : 1)
    end
    Process.wait(child)
    assert_predicate $CHILD_STATUS, :success?
    assert_predicate StackProf, :running?
    assert Beacon::Profiling.stop
    refute_empty Dir[File.join(@dir, "ruby-*-#{child}-*.pprof")]
  end

  def test_exception_samples_follow_active_trace_context
    config = Beacon::Profiling::Config.new(@env.merge('OTEL_PROFILING_EXCEPTION_ENABLED' => 'true',
                                                      'OTEL_PROFILING_EXCEPTION_SAMPLING_INTERVAL' => '1'))
    collector = Beacon::Profiling::Exceptions.new(config)
    context = OpenTelemetry::Trace::SpanContext.new(trace_id: ['1234567890abcdef1234567890abcdef'].pack('H*'),
                                                    span_id: ['1234567890abcdef'].pack('H*'))
    collector.start
    OpenTelemetry::Trace.with_span(OpenTelemetry::Trace.non_recording_span(context)) do
      raise 'private'
    rescue RuntimeError
      nil
    end
    collector.stop
    labels = collector.snapshot[:labels].values
    assert(labels.any? { |entry| entry['trace id'] == context.hex_trace_id && entry['span id'] == context.hex_span_id })
  ensure
    collector&.stop
  end

  def test_slow_receiver_has_bounded_queue_and_shutdown
    require 'socket'
    server = TCPServer.new('127.0.0.1', 0)
    receiver = Thread.new do
      connection = server.accept
      sleep 3
      connection.close
    end
    @env.merge!('OTEL_PROFILING_EXPORTER' => 'datakit', 'OTEL_PROFILING_UPLOAD_TIMEOUT' => '0.5',
                'OTEL_PROFILING_SHUTDOWN_TIMEOUT' => '0.1',
                'OTEL_PROFILING_PPROF_UPLOAD_URL' => "http://127.0.0.1:#{server.addr[1]}/profiles")
    assert Beacon::Profiling.start(env: @env)
    wait_for { Beacon::Profiling.stats[:dropped].positive? }
    assert_operator Beacon::Profiling.stats[:pending], :<=, 2
    refute Beacon::Profiling.stop
    refute Beacon::Profiling.start(env: @env)
    wait_for { !Beacon::Profiling.stats[:active] }
    assert Beacon::Profiling.stop
    assert_operator Beacon::Profiling.stats[:failed], :>, 0
  ensure
    server&.close
    receiver&.kill
  end

  def test_wall_does_not_include_timeout_watcher
    Timeout.timeout(1) { sleep 0.01 }
    wall = Beacon::Profiling::Wall.new(Beacon::Profiling::Config.new(@env))
    wall.start
    sleep 0.05
    wall.stop
    data = wall.snapshot
    assert_operator data[:samples], :>, 0
    refute(data[:frames].values.any? { |frame| frame[:name] == 'create_timeout_thread' })
  ensure
    wall&.stop
  end
end

# rubocop:enable Minitest/MultipleAssertions
