# frozen_string_literal: true

require_relative 'profiling/config'
require_relative 'profiling/session'

module Beacon
  # Opt-in profiling with independent sampling and export workers.
  module Profiling
    @mutex = Mutex.new

    class << self
      # @param env [Hash] environment configuration
      # @return [Boolean] whether a new profiler started
      def start(env: ENV)
        return false unless %w[true 1 yes on].include?(env['OTEL_PROFILING_ENABLED'].to_s.downcase)
        return false if @session && @session.pid != Process.pid

        @mutex.synchronize do
          return false if @session&.alive?

          config = Config.new(env)
          return false if config.exporter == 'none'

          require 'stackprof'
          session = Session.new(config)
          return false unless session.start

          @session = session
          unless @exit_hook
            at_exit { stop }
            @exit_hook = true
          end
          true
        end
      rescue StandardError, LoadError => e
        warn "Beacon profiling could not start (#{e.class})"
        false
      end

      # @return [Boolean] whether shutdown completed within its deadline
      def stop
        session = @session
        return false unless session && session.pid == Process.pid

        completed = session.stop
        warn 'Beacon profiling shutdown deadline exceeded; export is still pending' unless completed
        completed
      end

      # @return [Hash] process-local collection and delivery counters
      def stats
        return {} unless @session && @session.pid == Process.pid

        @session.stats
      end

      # Call in Puma/Unicorn worker initialization, including preloaded apps.
      # @param env [Hash] worker environment
      # @return [Boolean] whether the child profiler started
      def after_fork(env: ENV)
        if @session && @session.pid != Process.pid
          @session.discard_after_fork
          @session = nil
          @mutex = Mutex.new
        end
        start(env: env)
      end
    end
  end
end
