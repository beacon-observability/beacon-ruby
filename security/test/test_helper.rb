# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  enable_coverage :branch
  minimum_coverage 85
end
require 'minitest/autorun'
require 'beacon/security'
require 'rack/mock'
require 'json_schemer'

class MemoryLogger
  attr_reader :records

  def initialize
    @records = []
  end

  def on_emit(**record)
    @records << record
  end

  def events
    @records.map { |record| JSON.parse(record[:body]).merge('observed_at' => record[:timestamp].utc.iso8601(9)).tap { |event| event['occurrence_id'] = record[:attributes]['event_id'] if event['event_name'] == 'beacon.security.finding' } }
  end
end
