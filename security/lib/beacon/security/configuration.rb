# frozen_string_literal: true

module Beacon
  module Security
    # Environment binding of the shared opt-in configuration contract.
    # Security and local files default to false; SBOM defaults to true.
    # Only case-insensitive true enables a boolean. Invalid refresh values use 300.
    # @see https://github.com/beacon-observability/beacon-security-spec
    class Configuration
      attr_reader :enabled, :sbom_enabled, :local_output, :output, :evidence_file, :refresh_seconds

      def initialize(env = ENV)
        @enabled = boolean(env, 'BEACON_SECURITY_ENABLED', false)
        @sbom_enabled = boolean(env, 'BEACON_SECURITY_SBOM_ENABLED', true)
        @local_output = boolean(env, 'BEACON_SECURITY_LOCAL_OUTPUT_ENABLED', false)
        @output = env.fetch('BEACON_SECURITY_OUTPUT', 'beacon-security-output')
        @evidence_file = env['BEACON_SECURITY_EVIDENCE_FILE']
        value = env.fetch('BEACON_SECURITY_SBOM_REFRESH_SECONDS', '300')
        @refresh_seconds = /\A[0-9]+\z/.match?(value) && value.to_i.positive? ? value.to_i : 300
      end

      private

      def boolean(env, key, default)
        return default unless env.key?(key)

        env[key].to_s.downcase == 'true'
      end
    end
  end
end
