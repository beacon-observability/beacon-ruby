# frozen_string_literal: true

# rubocop:disable Minitest/MultipleAssertions

require_relative 'test_helper'

class ProfilingTest < Minitest::Test
  def teardown
    Beacon::Profiling.stop
  end

  def test_disabled_does_not_start_stackprof
    refute Beacon::Profiling.start(env: {})
    refute_predicate StackProf, :running?
  end

  def test_invalid_configuration_is_contained
    refute Beacon::Profiling.start(env: { 'OTEL_PROFILING_ENABLED' => 'true', 'OTEL_PROFILING_MODE' => 'heap' })
    refute_predicate StackProf, :running?
  end

  def test_cpu_and_wall_export_real_profiles
    %w[cpu wall].each do |mode|
      Dir.mktmpdir do |dir|
        env = { 'OTEL_PROFILING_ENABLED' => 'true', 'OTEL_PROFILING_MODE' => mode,
                'OTEL_PROFILING_PPROF_PATH' => dir }
        assert Beacon::Profiling.start(env: env)
        refute Beacon::Profiling.start(env: env)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.15
        Math.sqrt(1234) while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.03
        assert Beacon::Profiling.stop
        refute_predicate StackProf, :running?
        files = Dir[File.join(dir, '*.pprof')]
        assert_equal 1, files.size
        data = Zlib::GzipReader.open(files.first, &:read)
        assert_includes data, 'nanoseconds'
        assert_includes data, mode
      end
    end
  end

  def test_does_not_stop_another_profiler
    StackProf.start(mode: :wall)
    refute Beacon::Profiling.start(env: { 'OTEL_PROFILING_ENABLED' => 'true' })
    Beacon::Profiling.stop
    assert_predicate StackProf, :running?
  ensure
    StackProf.stop
    StackProf.results
  end
end

class ExportTest < Minitest::Test
  def teardown
    Beacon::Profiling.stop
  end

  def test_http_upload_contains_a_parseable_profile_and_metadata
    require 'socket'
    server = TCPServer.new('127.0.0.1', 0)
    received = Queue.new
    receiver = Thread.new do
      socket = server.accept
      headers = +''
      headers << socket.read(1) until headers.end_with?("\r\n\r\n")
      length = headers[/Content-Length: (\d+)/i, 1].to_i
      received << [headers, socket.read(length)]
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      socket.close
    end
    env = { 'OTEL_PROFILING_ENABLED' => 'true', 'OTEL_SERVICE_NAME' => 'profile-test',
            'OTEL_RESOURCE_ATTRIBUTES' => 'service.version=2,deployment.environment.name=local',
            'OTEL_PROFILING_PPROF_HEADERS' => 'X-Test:synthetic',
            'OTEL_PROFILING_PPROF_UPLOAD_URL' => "http://127.0.0.1:#{server.addr[1]}/profiling/v1/input" }
    assert Beacon::Profiling.start(env: env)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.15
    Math.sqrt(123) while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    Beacon::Profiling.stop
    assert receiver.join(3)
    headers, body = received.pop
    assert_includes headers, 'POST /profiling/v1/input'
    assert_includes body, 'service:profile-test'
    assert_includes body, 'version:2'
    assert_includes body, 'env:local'
    assert_includes body, 'filename="auto.pprof"'
    assert_includes headers, 'X-Test: synthetic'
    profile = body.split("Content-Type: application/octet-stream\r\n\r\n", 2).last.split("\r\n--", 2).first
    assert_includes Zlib::GzipReader.new(StringIO.new(profile)).read, 'nanoseconds'
  ensure
    server&.close
    receiver&.kill
  end

  def test_periodic_flush_and_failed_export_do_not_stop_the_application
    Dir.mktmpdir do |dir|
      env = { 'OTEL_PROFILING_ENABLED' => 'true', 'OTEL_PROFILING_UPLOAD_INTERVAL' => '1',
              'OTEL_PROFILING_PPROF_PATH' => dir }
      assert Beacon::Profiling.start(env: env)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.3
      sleep 0.01 while Dir[File.join(dir, '*.pprof')].empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      refute_empty Dir[File.join(dir, '*.pprof')]
      Beacon::Profiling.stop
      env['OTEL_PROFILING_PPROF_PATH'] = File.join(dir, 'blocked', 'child')
      File.write(File.join(dir, 'blocked'), 'file')
      assert Beacon::Profiling.start(env: env)
      sleep 0.1
      assert Beacon::Profiling.stop
      refute_predicate StackProf, :running?
    end
  end

  def test_invalid_url_and_intervals
    %w[ftp://localhost http://user:secret@localhost].each do |url|
      refute Beacon::Profiling.start(env: { 'OTEL_PROFILING_ENABLED' => 'true', 'OTEL_PROFILING_PPROF_UPLOAD_URL' => url })
    end
    refute Beacon::Profiling.start(env: { 'OTEL_PROFILING_ENABLED' => 'true', 'OTEL_PROFILING_SAMPLING_INTERVAL' => '0' })
    refute Beacon::Profiling.start(env: { 'OTEL_PROFILING_ENABLED' => 'true', 'OTEL_PROFILING_UPLOAD_INTERVAL' => '0' })
  end
end

# rubocop:enable Minitest/MultipleAssertions
