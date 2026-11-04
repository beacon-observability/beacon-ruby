# frozen_string_literal: true

require 'digest'
module Beacon
  module Security
    # Language-neutral fingerprint v1, including UTF-16 signature ordering.
    module Fingerprint
      module_function

      # Normalize malformed encodings before hashing or exporting structural names.
      def text(value)
        value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
      end

      # Internal service scope only; never exported as a second v2 identity.
      def application_id(resource)
        "app-#{Digest::SHA256.hexdigest("#{resource.fetch('service.namespace', '')}|#{resource.fetch('service.name', 'unknown_service:ruby')}")}"
      end

      # Hash length-prefixed segments before optional evidence compaction.
      def finding(application_id:, language:, rule:, sink:, source_signatures:)
        signatures = source_signatures.map { |s| text(s) }.uniq.sort_by { |s| s.encode(Encoding::UTF_16BE).bytes }
        segments = ['1', application_id, language, rule, *%w[role function location operation path_role input_part].map { |key| sink.fetch(key, '') }, *signatures]
        digest = Digest::SHA256.new
        segments.each do |segment|
          bytes = text(segment)
          digest.update([bytes.bytesize].pack('N')).update(bytes)
        end
        "finding-#{digest.hexdigest}"
      end
    end
  end
end
