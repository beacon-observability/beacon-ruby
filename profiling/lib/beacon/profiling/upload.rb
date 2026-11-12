# frozen_string_literal: true

require 'net/http'
require 'json'
require 'time'
require 'timeout'

module Beacon
  module Profiling
    # Sends the pprof multipart format accepted by profiling receivers.
    class Upload
      def initialize(config)
        @config = config
        @uri = URI(config.endpoint)
        raise ArgumentError, 'expected an HTTP(S) upload URL' unless %w[http https].include?(@uri.scheme) && @uri.host && !@uri.userinfo && !@uri.fragment

        @tags = config.tags.map { |key, value| "#{key}:#{value.to_s.gsub(/[\r\n,]/, '_')}" }.join(',')
      end

      # Uploads one window; raises on transport errors or non-success responses.
      # @return [void]
      def export(profile, mode, started, duration)
        filename = 'auto.pprof'
        boundary = SecureRandom.hex(16)
        event = { version: '4', profiler: 'ddtrace', family: 'ruby', language: 'ruby', format: 'pprof',
                  attachments: [filename], tags_profiler: @tags,
                  start: Time.at(Rational(started, 1_000_000_000)).utc.iso8601(9),
                  end: Time.at(Rational(started + duration, 1_000_000_000)).utc.iso8601(9) }
        body = +"--#{boundary}\r\nContent-Disposition: form-data; name=\"auto\"; filename=\"#{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n".b
        body << profile << "\r\n--#{boundary}\r\nContent-Disposition: form-data; name=\"event\"; filename=\"event.json\"\r\nContent-Type: application/json\r\n\r\n"
        body << JSON.generate(event) << "\r\n--#{boundary}--\r\n"
        request = Net::HTTP::Post.new(@uri)
        @config.headers.each { |key, value| request[key] = value }
        request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
        request.body = body
        http = Net::HTTP.new(@uri.host, @uri.port, nil)
        http.use_ssl = @uri.scheme == 'https'
        http.open_timeout = http.read_timeout = http.write_timeout = @config.timeout
        http.max_retries = 0
        Timeout.timeout(@config.timeout) do
          http.start do |connection|
            connection.request(request) do |response|
              raise "profile upload rejected: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
            end
          end
        end
      end
    end
  end
end
