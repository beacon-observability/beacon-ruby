# frozen_string_literal: true

require 'English'

require 'test_helper'
require 'net/http'
require 'socket'
require 'tmpdir'
require 'opentelemetry/sdk'
require 'opentelemetry/sdk/logs'

class IntegrationTest < Minitest::Test
  def setup
    @logger = MemoryLogger.new
    @runtime = Beacon::Security.start(configuration: Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_ENABLED' => 'false'), logger: @logger)
  end

  def teardown
    @runtime.shutdown
  end

  def request(query, &application)
    result = Beacon::Security::Middleware.new(application, runtime: @runtime).call(Rack::MockRequest.env_for("/?#{query}"))
    @runtime.force_flush
    result
  end

  def test_real_file_calls_and_application_exception
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'private-file-name')
      error = assert_raises(ArgumentError) do
        request('path=private-file-name') do |_env|
          assert_equal 5, File.write(path, 'hello')
          assert_equal 'hello', File.read(path)
          raise ArgumentError, 'private-message'
        end
      end
      assert_equal 'private-message', error.message
      @runtime.force_flush
      assert_equal(%w[write read], @logger.events.map { |event| event.dig('sink', 'operation') })
      assert(@logger.events.all? { |event| event.dig('request', 'error_type') == 'ArgumentError' })
      refute_includes @logger.records.to_s, 'private-file-name'
      refute_includes @logger.records.to_s, 'private-message'
      assert_nil Beacon::Security.current_request
    end
  end

  def test_file_delete_observes_each_path_without_changing_result
    Dir.mktmpdir do |directory|
      first = File.join(directory, 'first-delete')
      second = File.join(directory, 'second-delete')
      File.write(first, '')
      File.write(second, '')
      request('name=second-delete') do |_env|
        assert_equal 2, File.delete(first, second)
        [200, {}, []]
      end
      assert_equal 'delete', @logger.events.fetch(0).dig('sink', 'operation')
    end
  end

  def test_real_kernel_calls_preserve_visibility_arguments_and_result
    request('arg=beacon-command-value') do |_env|
      assert Kernel.system('/bin/echo', 'beacon-command-value', out: File::NULL)
      assert system('/bin/echo', 'beacon-command-value', out: File::NULL)
      pid = spawn('/bin/echo', 'beacon-command-value', out: File::NULL)
      Process.wait(pid)
      assert_equal 0, $CHILD_STATUS.exitstatus
      assert Kernel.system('echo beacon-command-value', out: File::NULL)
      [200, {}, []]
    end
    assert_includes @logger.events.map { |e| e['rule'] }, 'command_execution'
    assert_includes @logger.events.map { |e| e['rule'] }, 'command_injection'
    refute_respond_to Object.new, :system
    assert_respond_to Kernel, :system
  end

  def test_real_http_request
    server = TCPServer.new('127.0.0.1', 0)
    worker = Thread.new do
      client = server.accept
      line = client.gets
      line = client.gets until line == "\r\n" || line.nil?
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    ensure
      client&.close
    end
    request('host=127.0.0.1&query=private-http-value') do |_env|
      http = Net::HTTP.new('127.0.0.1', server.addr[1], nil)
      assert_equal 'ok', http.get('/?q=private-http-value').body
      [200, {}, []]
    end
    assert_equal(%w[ssrf http_request_input], @logger.events.map { |event| event['rule'] })
    refute_includes @logger.records.to_s, 'private-http-value'
  ensure
    server&.close
    worker&.join(1)
    worker&.kill
  end

  def test_real_otel_logger_mapping_and_trace_context
    resource = OpenTelemetry::SDK::Resources::Resource.create('service.name' => 'security-test', 'service.namespace' => 'test')
    provider = OpenTelemetry::SDK::Logs::LoggerProvider.new(resource: resource)
    exporter = OpenTelemetry::SDK::Logs::Export::InMemoryLogRecordExporter.new
    provider.add_log_record_processor(OpenTelemetry::SDK::Logs::Export::SimpleLogRecordProcessor.new(exporter))
    @runtime.shutdown
    @runtime = Beacon::Security::Runtime.new(logger: provider.logger(name: 'io.beacon.security', version: Beacon::Security::VERSION),
                                             configuration: Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_ENABLED' => 'false'),
                                             resource: resource.attribute_enumerator.to_h).start
    traces = OpenTelemetry::SDK::Trace::TracerProvider.new
    tracer = traces.tracer('test')
    tracer.in_span('server', kind: :server) do |server|
      request('id=private-otel-value') do |_env|
        tracer.in_span('child') do
          @runtime.observe('sql_injection', 'select private-otel-value', function: 'DB.query', role: 'sql_template')
        end
        [200, {}, []]
      end
      record = exporter.emitted_log_records.first
      event = JSON.parse(record.body)
      assert_equal server.context.hex_trace_id, event['trace_id']
      assert_equal server.context.hex_span_id, event['server_span_id']
      refute_equal event['server_span_id'], event['current_span_id']
      assert_equal 9, record.severity_number
      assert_equal 'INFO', record.severity_text
      assert_equal event['event_name'], record.event_name
      assert_equal event['source'], record.attributes['source']
      assert_equal 'io.beacon.security', record.instrumentation_scope.name
      assert_equal 'security-test', record.resource.attribute_enumerator.to_h['service.name']
    end
  ensure
    provider&.shutdown
    traces&.shutdown
  end

  def test_fiber_and_thread_context_are_isolated
    entered = Queue.new
    release = Queue.new
    thread = Thread.new do
      request('x=thread-private') do |_env|
        entered << true
        release.pop
        @runtime.observe('sql_injection', 'thread-private', function: 'DB.query', role: 'sql_template')
        [200, {}, []]
      end
    end
    entered.pop
    assert_nil Beacon::Security.current_request
    request('x=fiber-private') do |_env|
      Fiber.new { assert_nil Beacon::Security.current_request }.resume
      @runtime.observe('sql_injection', 'thread-private', function: 'DB.query', role: 'sql_template')
      [200, {}, []]
    end
    release << true
    thread.join
    assert_equal 1, @logger.events.size
  ensure
    release << true if release
    thread&.join(1)
  end
end
