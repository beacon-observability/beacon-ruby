# frozen_string_literal: true

require 'test_helper'
require 'pg'
require 'mysql2'

class DatabaseTest < Minitest::Test
  def setup
    @logger = MemoryLogger.new
    @runtime = Beacon::Security.start(configuration: Beacon::Security::Configuration.new('BEACON_SECURITY_ENABLED' => 'true', 'BEACON_SECURITY_SBOM_ENABLED' => 'false'), logger: @logger)
  end

  def teardown
    @runtime.shutdown
    @db&.close
  end

  def test_postgres_templates_and_bound_values
    skip 'Set BEACON_TEST_PG_PORT for the disposable PostgreSQL service' unless ENV['BEACON_TEST_PG_PORT']
    @db = PG.connect(host: '127.0.0.1', port: ENV.fetch('BEACON_TEST_PG_PORT'), user: 'postgres', password: 'beacon-local-test')
    execute_request do
      assert_equal 'private-db-value', @db.exec_params('SELECT $1::text', ['private-db-value']).getvalue(0, 0)
      @db.prepare('bound', 'SELECT $1::text')
      assert_equal 'private-db-value', @db.exec_prepared('bound', ['private-db-value']).getvalue(0, 0)
    end
    assert_empty @logger.events
    execute_request { @db.exec("SELECT 'private-db-value'") }
    assert_equal 'sql_injection', @logger.events.fetch(0)['rule']
    refute_includes @logger.records.to_s, 'private-db-value'
  end

  def test_mysql_templates_and_bound_values
    skip 'Set BEACON_TEST_MYSQL_PORT for the disposable MySQL service' unless ENV['BEACON_TEST_MYSQL_PORT']
    @db = Mysql2::Client.new(host: '127.0.0.1', port: ENV.fetch('BEACON_TEST_MYSQL_PORT').to_i, username: 'root', password: 'beacon-local-test', database: 'security_test')
    execute_request do
      statement = @db.prepare('SELECT ? AS value')
      assert_equal 'private-db-value', statement.execute('private-db-value').first.fetch('value')
      statement.close
    end
    assert_empty @logger.events
    execute_request { @db.query("SELECT 'private-db-value' AS value") }
    assert_equal 'sql_injection', @logger.events.fetch(0)['rule']
    refute_includes @logger.records.to_s, 'private-db-value'
  end

  private

  def execute_request
    app = lambda do |_env|
      yield
      [200, {}, []]
    end
    Beacon::Security::Middleware.new(app, runtime: @runtime).call(Rack::MockRequest.env_for('/?name=private-db-value'))
    @runtime.force_flush
  end
end
