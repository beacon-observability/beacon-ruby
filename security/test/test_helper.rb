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
    @records.map { |record| JSON.parse(record[:body]) }
  end
end
