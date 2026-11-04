# frozen_string_literal: true

module Beacon
  module Security
    # Place inside the OTel Rack server-span middleware. Does not read rack.input.
    class Middleware
      # @param app [#call] Rack application
      # @param runtime [Runtime] Security runtime configured in this worker
      def initialize(app, runtime: Security.runtime)
        @app = app
        @runtime = runtime
      end

      # Restore nested/fiber-local request state even when the application raises.
      def call(env)
        return @app.call(env) unless @runtime&.enabled?

        previous = Thread.current[CONTEXT_KEY]
        request = begin
          Request.new(@runtime, env)
        rescue StandardError
          nil
        end
        Thread.current[CONTEXT_KEY] = request
        begin
          response = @app.call(env)
        rescue Exception => e # rubocop:disable Lint/RescueException
          finish(request, error: e)
          raise
        else
          finish(request, status: response[0])
          response
        ensure
          Thread.current[CONTEXT_KEY] = previous
        end
      end

      private

      def finish(request, **context)
        request&.finish(**context)
      rescue StandardError
        nil
      end
    end
  end
end
