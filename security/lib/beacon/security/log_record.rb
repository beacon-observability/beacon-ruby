# frozen_string_literal: true

module Beacon
  module Security
    # Native metadata and compact v2 Body, before queueing or SDK conversion.
    module LogRecord
      module_function

      # Build native metadata without changing the retained event fields.
      def bind(event)
        inventory = event['event_name'] == 'beacon.security.sbom.inventory'
        unless event['schema_version'] == 2 && event['source'] == (inventory ? 'beacon_security_sbom' : 'beacon_security') &&
               (inventory || event['event_name'] == 'beacon.security.finding')
          raise ArgumentError, 'unsupported Security event'
        end

        value = event.fetch('observed_at')
        raise ArgumentError, 'invalid Security event time' unless /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})\z/.match?(value)

        raise ArgumentError, 'invalid calendar date' unless Date.valid_date?(value[0, 4].to_i, value[5, 2].to_i, value[8, 2].to_i)

        time = Time.iso8601(value)
        raise ArgumentError, 'invalid calendar time' unless time.strftime('%Y-%m-%dT%H:%M:%S') == value[0, 19]

        nanos = (time.to_r * 1_000_000_000).to_i
        raise RangeError, 'Security event time out of range' unless (1..9_223_372_036_854_775_807).cover?(nanos)

        identity = [event['source'], event['event_name'], event['instance_id'], value, (event['part_index'] || 0).to_s]
        id = inventory ? "inventory-#{Digest::SHA256.hexdigest(JSON.generate(identity))}" : event.fetch('occurrence_id')
        raise ArgumentError, 'missing Security event ID' unless id.is_a?(String) && !id.empty?

        { 'time_unix_nano' => nanos.to_s, 'body' => JSON.generate(event.except('observed_at', 'occurrence_id')),
          'attributes' => { 'event_id' => id, 'source' => event['source'] } }
      end
    end
  end
end
