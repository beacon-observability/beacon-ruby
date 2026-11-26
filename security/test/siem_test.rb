# frozen_string_literal: true

require 'test_helper'
require 'digest'

class SiemTest < Minitest::Test
  def test_packaged_provenance_matches_normative_schema_bytes
    contract = JSON.parse(File.read(File.join(__dir__, '../contract.json')))
    assert_equal Beacon::Security::SPEC_COMMIT, contract['commit']
    assert_equal 'beacon-security-log-body-v1', contract['output_profile']
    { 'schema_sha256' => 'beacon-security-event-v2.schema.json', 'siem_schema_sha256' => 'beacon-security-siem-v1.schema.json', 'log_body_schema_sha256' => 'beacon-security-log-body-v1.schema.json' }.each do |key, file|
      assert_equal contract[key], Digest::SHA256.file(File.join(__dir__, 'fixtures', file)).hexdigest
    end
  end

  def test_reference_vectors_preserve_original_bytes_and_semantics
    root = File.join(__dir__, 'fixtures/spec')
    JSON.parse(File.read(File.join(root, 'test-vectors/siem-v1.json')))['vectors'].each do |vector|
      raw = File.read(File.join(root, vector['input']))
      expected = JSON.parse(File.read(File.join(root, vector['expected'])))
      actual = Beacon::Security::Siem.normalize(raw, vector['resource'], vector['context'])
      assert_equal expected, actual, vector['name']
      assert_equal raw, actual['message']
    end
  end

  def test_filtering_precedes_queue_admission_and_preserves_unknown
    config = Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_ENABLED' => 'false')
    logger = MemoryLogger.new
    runtime = Beacon::Security::Runtime.new(configuration: config, logger: logger)
    event = JSON.parse(File.read(File.join(__dir__, 'fixtures/spec/examples/finding-v2.json')))
    event['attack_evidence']['status'] = 'no_evidence'
    1100.times { runtime.emit(event) }
    assert_equal 0, runtime.instance_variable_get(:@queue).size
    event['attack_evidence']['status'] = 'unknown'
    runtime.emit(event)
    assert_equal 1, runtime.instance_variable_get(:@queue).size
    config.instance_variable_set(:@export_no_evidence, true)
    runtime.emit(event.merge('attack_evidence' => { 'status' => 'no_evidence', 'reason' => 'test' }))
    assert_equal 2, runtime.instance_variable_get(:@queue).size
  ensure
    runtime&.shutdown
  end

  def test_final_envelope_budget_and_single_oversized_dependency
    config = Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_ENABLED' => 'false')
    runtime = Beacon::Security::Runtime.new(configuration: config, logger: MemoryLogger.new)
    base = runtime.envelope('beacon.security.sbom.inventory', 'beacon_security_sbom').merge('started_at' => Time.now.utc.iso8601, 'uptime_ms' => 0)
    dependencies = Array.new(100) { |i| { 'name' => "#{i}#{'\"汉😀' * 100}", 'version' => '1' } }
    parts = runtime.send(:inventory_parts, base, dependencies)
    assert_equal(dependencies, parts.flat_map { |part| part['dependencies'] })
    parts.each do |part|
      wire = Beacon::Security::LogRecord.bind(part)['body']
      assert_operator wire.bytesize, :<=, Beacon::Security::Runtime::MAX_EVENT_BYTES
    end
    assert_raises(RangeError) { runtime.send(:inventory_parts, base, [{ 'name' => 'x' * 100_000, 'version' => '1' }]) }
  ensure
    runtime&.shutdown
  end
end
