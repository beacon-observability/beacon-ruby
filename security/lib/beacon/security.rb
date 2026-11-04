# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'
require 'opentelemetry-api'
require 'opentelemetry-logs-api'
require_relative 'security/version'
require_relative 'security/configuration'
require_relative 'security/fingerprint'
require_relative 'security/request'
require_relative 'security/runtime'
require_relative 'security/middleware'
require_relative 'security/hooks'

module Beacon
  # Opt-in runtime observations; host applications own OpenTelemetry providers.
  module Security
    CONTEXT_KEY = :beacon_security_request
    class << self
      # Configure after the application configures its OpenTelemetry providers.
      # @return [Runtime]
      def start(**)
        @runtime&.shutdown
        @runtime = Runtime.new(**)
        Hooks.install if @runtime.enabled?
        @runtime.start
        @runtime
      end

      # @return [Runtime, nil] current runtime
      attr_reader :runtime

      # @return [Request, nil] fiber-local synchronous request observation
      def current_request
        Thread.current[CONTEXT_KEY]
      end

      # Internal hook boundary: instrumentation failures never alter the call.
      def observe(rule, value, **sink)
        current_request&.observe(rule, value, **sink)
      rescue StandardError
        nil
      end
    end
  end
end
