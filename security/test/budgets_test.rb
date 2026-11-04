# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class BudgetsTest < Minitest::Test
  def setup
    @logger = MemoryLogger.new
    @config = Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_ENABLED' => 'false')
    @runtime = Beacon::Security::Runtime.new(configuration: @config, logger: @logger).start
  end

  def teardown
    @runtime.shutdown
  end

  def test_source_and_sink_budgets_are_declared
    query = (0...70).map { |i| "k#{i}=value#{i}" }.join('&')
    Beacon::Security::Middleware.new(lambda { |_env|
      @runtime.observe('sql_injection', 'value0', function: 'DB.query', role: 'sql_template')
      @runtime.observe('sql_injection', 'x' * 65_537, function: 'DB.query', role: 'sql_template')
      [200, {}, []]
    }, runtime: @runtime).call(Rack::MockRequest.env_for("/?#{query}"))
    @runtime.force_flush
    event = @logger.events.fetch(0)
    assert event['truncated']
    assert_equal 'request_budget', event['truncation_reason']
    refute event['collection_complete']
  end

  def test_exporter_failure_does_not_change_host_result
    logger = Object.new
    def logger.on_emit(**)
      raise IOError, 'offline'
    end
    @runtime.shutdown
    @runtime = Beacon::Security::Runtime.new(configuration: @config, logger: logger).start
    result = [202, {}, []]
    app = lambda { |_env|
      @runtime.observe('sql_injection', 'secret', function: 'DB.query', role: 'sql_template')
      result
    }
    assert_same result, Beacon::Security::Middleware.new(app, runtime: @runtime).call(Rack::MockRequest.env_for('/?x=secret'))
    assert @runtime.force_flush
  end

  def test_inventory_multipart_fits_budget_and_preserves_all_dependencies
    base = @runtime.envelope('beacon.security.sbom.inventory', 'beacon_security_sbom').merge('started_at' => Time.now.utc.iso8601(9), 'uptime_ms' => 0)
    dependencies = Array.new(2000) { |i| { 'name' => "package-#{i}-#{'x' * 64}", 'version' => '1.0' } }
    parts = @runtime.send(:inventory_parts, base, dependencies)
    assert_operator parts.size, :>=, 2
    assert_equal(dependencies, parts.flat_map { |part| part['dependencies'] })
    schema = JSONSchemer.schema(JSON.parse(File.read(File.join(__dir__, 'fixtures/beacon-security-event-v2.schema.json'))))
    parts.each_with_index do |part, index|
      assert_operator JSON.generate(part).bytesize, :<=, 65_536
      assert_equal index, part['part_index']
      assert_equal parts.size, part['part_count']
      assert schema.valid?(part)
    end
  end

  def test_local_files_require_explicit_opt_in
    Dir.mktmpdir do |directory|
      output = File.join(directory, 'diagnostics')
      evidence = File.join(directory, 'evidence.jsonl')
      config = Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_ENABLED' => 'false',
                                                   'BEACON_SECURITY_LOCAL_OUTPUT_ENABLED' => 'true', 'BEACON_SECURITY_OUTPUT' => output, 'BEACON_SECURITY_EVIDENCE_FILE' => evidence)
      @runtime.shutdown
      @runtime = Beacon::Security::Runtime.new(configuration: config, logger: @logger).start
      app = lambda { |_env|
        @runtime.observe('sql_injection', 'private-local', function: 'DB.query', role: 'sql_template')
        [200, {}, []]
      }
      Beacon::Security::Middleware.new(app, runtime: @runtime).call(Rack::MockRequest.env_for('/?id=private-local'))
      @runtime.force_flush
      assert_equal 1, Dir[File.join(output, '*.json')].size
      assert_equal 0o600, File.stat(evidence).mode & 0o777
      refute_includes File.read(evidence), 'private-local'
    end
  end

  def test_unchanged_periodic_inventory_republishes_and_shutdown_stops_worker
    @runtime.shutdown
    config = Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_REFRESH_SECONDS' => '1')
    signal = Queue.new
    logger = @logger
    logger.define_singleton_method(:on_emit) do |**record|
      @records << record
      signal << true
    end
    @runtime = Beacon::Security::Runtime.new(configuration: config, logger: logger).start
    assert signal.pop(timeout: 3)
    assert signal.pop(timeout: 3)
    @runtime.shutdown
    events = @logger.events
    assert_operator events.size, :>=, 2
    assert_equal events[0]['dependencies'], events[1]['dependencies']
    refute_predicate @runtime, :enabled?
  end

  def test_full_queue_and_slow_exporter_do_not_block_application
    entered = Queue.new
    release = Queue.new
    logger = Object.new
    logger.define_singleton_method(:on_emit) do |**_record|
      entered << true
      release.pop
    end
    @runtime.shutdown
    @runtime = Beacon::Security::Runtime.new(configuration: @config, logger: logger).start
    event = @runtime.envelope('beacon.security.sbom.inventory', 'beacon_security_sbom').merge('dependencies' => [], 'started_at' => Time.now.utc.iso8601, 'uptime_ms' => 0)
    @runtime.emit(event)
    assert entered.pop(timeout: 1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    1100.times { @runtime.emit(event) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    refute @runtime.force_flush
  ensure
    1102.times { release << true } if release
  end

  def test_refresh_defaults_and_unicode_sorting
    %w[0 -1 invalid 1.5].each do |value|
      assert_equal 300, Beacon::Security::Configuration.new('BEACON_SECURITY_SBOM_REFRESH_SECONDS' => value).refresh_seconds
    end
    malformed = [0xD800].pack('n').force_encoding(Encoding::UTF_16BE)
    assert_equal "\uFFFD", Beacon::Security::Fingerprint.text(malformed)
  end
end
