# frozen_string_literal: true

require 'test_helper'
require 'open3'

class SecurityTest < Minitest::Test
  def setup
    @logger = MemoryLogger.new
    @runtime = Beacon::Security::Runtime.new(configuration: Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_ENABLED' => 'false'), logger: @logger,
                                             resource: { 'service.name' => 'orders' }).start
  end

  def teardown
    @runtime.shutdown
  end

  def test_default_is_disabled_and_legacy_keys_do_not_enable
    config = Beacon::Security::Configuration.new('SECURITY_ENABLED' => 'true')
    refute config.enabled
    assert config.sbom_enabled
    refute config.local_output
  end

  def test_fingerprint_vectors
    fixture = File.read(File.join(__dir__, 'fixtures/fingerprint-v1.json'))
    # Ruby JSON rejects lone surrogates; normalize JSON escapes before parsing, as required by the contract.
    fixture = fixture.gsub(/\\u[dD][89a-fA-F][0-9a-fA-F]{2}/, '\\ufffd')
    JSON.parse(fixture).fetch('vectors').each do |vector|
      input = vector.fetch('input').transform_keys(&:to_sym)
      assert_equal vector.fetch('expected'), Beacon::Security::Fingerprint.finding(**input), vector.fetch('name')
    end
  end

  def test_rack_finding_is_private_deduplicated_and_schema_valid
    app = lambda do |_env|
      2.times { @runtime.observe('sql_injection', 'SELECT secret-value', function: 'DB.query', role: 'sql_template', location: 'orders.rb:10') }
      [200, {}, []]
    end
    middleware = Beacon::Security::Middleware.new(app, runtime: @runtime)
    middleware.call(Rack::MockRequest.env_for('/?customer=secret-value'))
    @runtime.force_flush
    assert_equal 1, @logger.events.size
    event = @logger.events.first
    assert_equal 'unknown', event.dig('attack_evidence', 'status')
    assert_equal 200, event.dig('request', 'status_code')
    assert_equal 'customer', event.fetch('sources').first.fetch('name')
    refute_includes JSON.generate(event), 'secret-value'
    assert_schema(event)
    middleware.call(Rack::MockRequest.env_for('/?customer=secret-value'))
    @runtime.force_flush
    assert_equal event['finding_id'], @logger.events.last['finding_id']
    refute_equal event['occurrence_id'], @logger.events.last['occurrence_id']
  end

  def test_bound_parameter_does_not_match_sql_template
    middleware = Beacon::Security::Middleware.new(lambda { |_env|
      @runtime.observe('sql_injection', 'SELECT * FROM users WHERE id = $1', function: 'PG.exec_params', role: 'sql_template')
      [200, {}, []]
    }, runtime: @runtime)
    middleware.call(Rack::MockRequest.env_for('/?id=private-value'))
    assert_empty @logger.events
  end

  def test_disabled_middleware_preserves_application_result
    runtime = Beacon::Security::Runtime.new(logger: @logger, configuration: Beacon::Security::Configuration.new({}))
    result = [201, {}, []]
    assert_same result, Beacon::Security::Middleware.new(->(_env) { result }, runtime: runtime).call({})
    assert_empty @logger.events
  end

  def test_inventory_schema_and_process_timing
    @runtime.instance_variable_get(:@configuration).instance_variable_set(:@sbom_enabled, true)
    @runtime.collect_inventory
    @runtime.force_flush
    first = @logger.events.last
    assert_schema(first)
    assert(first['dependencies'].any? { |dep| dep['name'] == 'minitest' })
    @runtime.collect_inventory
    @runtime.force_flush
    last = @logger.events.last
    assert_equal first['started_at'], last['started_at']
    assert_operator last['observed_at'], :>, first['observed_at']
    assert_operator last['uptime_ms'], :>=, first['uptime_ms']
  end

  def test_api_only_startup_without_logs_sdk
    program = <<~RUBY
      require 'beacon/security'
      config = Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_ENABLED' => 'false')
      runtime = Beacon::Security.start(configuration: config)
      puts runtime.enabled?
      runtime.shutdown
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', program)
    assert_predicate status, :success?, error
    assert_equal "true\n", output
  end

  private

  def assert_schema(event)
    schema = JSON.parse(File.read(File.join(__dir__, 'fixtures/beacon-security-event-v2.schema.json')))
    assert_empty JSONSchemer.schema(schema).validate(event).to_a
  end
end
