# frozen_string_literal: true

require 'test_helper'

class LogRecordTest < Minitest::Test
  def test_shared_log_binding_examples
    root = File.join(__dir__, 'fixtures/spec/examples')
    names = { 'finding.json' => 'finding-v2.json', 'finding-occurrence.json' => 'finding-occurrence-v2.json', 'sbom-inventory.json' => 'sbom-inventory-v2.json' }
    Dir.glob(File.join(root, 'log-records/*.json')).each do |path|
      name = File.basename(path)
      input_name = names.fetch(name, "siem/inputs/#{name}")
      input = JSON.parse(File.read(File.join(root, input_name)))
      expected = JSON.parse(File.read(path))
      actual = Beacon::Security::LogRecord.bind(input)
      assert_equal expected['time_unix_nano'], actual['time_unix_nano']
      assert_equal expected['attributes'].slice('event_id', 'source'), actual['attributes']
      assert_equal JSON.parse(expected['body']), JSON.parse(actual['body'])
      refute_match(/[\r\n]/, actual['body'])
      assert_equal actual, Beacon::Security::LogRecord.bind(input)
    end
  end

  def test_precision_and_invalid_times
    event = JSON.parse(File.read(File.join(__dir__, 'fixtures/spec/examples/finding-v2.json')))
    event['observed_at'] = '2026-10-02T00:00:00.123456789Z'
    assert_equal '1790899200123456789', Beacon::Security::LogRecord.bind(event)['time_unix_nano']
    ['bad', '2026-02-30T00:00:00Z', '2026-10-02T00:00:60Z', '1970-01-01T00:00:00Z', '1969-12-31T23:59:59Z', '2263-01-01T00:00:00Z'].each do |time|
      assert_raises(ArgumentError, RangeError) { Beacon::Security::LogRecord.bind(event.merge('observed_at' => time)) }
    end
  end
end
