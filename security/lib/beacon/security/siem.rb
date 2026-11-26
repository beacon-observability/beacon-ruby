# frozen_string_literal: true

require 'digest'
require 'ipaddr'

module Beacon
  module Security
    # Historical SIEM reference only; producers use LogRecord.
    module Siem
      module_function

      # Retain configured text without using blank identities.
      def nonempty(value)
        value.is_a?(String) && !value.strip.empty? ? value : ''
      end

      # Preserve raw bytes while projecting trusted Resource/context values.
      def normalize(raw, resource = {}, context = {})
        body = JSON.parse(raw)
        inventory = body['event_name'] == 'beacon.security.sbom.inventory'
        expected_source = inventory ? 'beacon_security_sbom' : 'beacon_security'
        unless body['schema_version'] == 2 && body['source'] == expected_source &&
               (inventory || body['event_name'] == 'beacon.security.finding') &&
               !body.key?('server_span_id') && !body.key?('current_span_id')
          raise ArgumentError, 'unsupported Security event'
        end

        identity = [body['source'], body['event_name'], body['instance_id'], body['observed_at'], (body['part_index'] || 0).to_s]
        ip = nonempty(context['client_ip'])
        ip = '' unless /\A[0-9a-fA-F:.]+\z/.match?(ip) && IPAddr.new(ip)
        result = {
          'time' => body.fetch('observed_at'),
          'event_id' => inventory ? "inventory-#{Digest::SHA256.hexdigest(JSON.generate(identity))}" : body.fetch('occurrence_id'),
          'event_class' => inventory ? 'software_inventory_info' : 'security_finding',
          'source' => expected_source, 'service' => nonempty(resource['service.name']),
          'tenant_id' => [context['tenant_id'], resource['tenant.id']].map { |value| nonempty(value) }.find { |value| !value.empty? } || 'default',
          'actor' => inventory ? '' : nonempty(context['actor']), 'ip' => inventory ? '' : ip,
          'action' => inventory ? 'inventory_snapshot' : body.fetch('rule'),
          'target' => inventory ? body.fetch('instance_id') : body.fetch('finding_id'),
          'target_type' => inventory ? 'process' : 'finding', 'outcome' => inventory ? 'success' : 'unknown',
          'status' => 'info', 'severity' => 'informational', 'message' => raw
        }
        result.merge(body.slice('instance_id', 'trace_id', 'span_id', 'trace_flags'))
      rescue IPAddr::InvalidAddressError
        normalize(raw, resource, context.merge('client_ip' => ''))
      end
    end
  end
end
