# frozen_string_literal: true

require "active_record"

module Hanikamu
  module RateLimit
    module Storage
      # Captures exceptions and HTTP responses into the database for the
      # learning UI. Users later classify these events as rate-limit signals
      # or noise, helping teams understand their API's rate-limit behaviour.
      #
      # All persistence is fire-and-forget: failures are logged but never
      # re-raised, so the capture layer never disrupts the rate-limited call.
      class EventCapture
        class << self
          # Capture an exception caught by the error-handling mixin.
          #
          # @param registry_name [Symbol, String] the registered limit name
          # @param error [Exception] the caught exception
          def capture_exception(registry_name, error, adaptive_rate: nil)
            with_connection do
              attrs = {
                registry_name: registry_name.to_s,
                event_type: "exception",
                exception_class: error.class.name,
                exception_message: error.message.to_s.truncate(2000),
                adaptive_rate: adaptive_rate
              }
              attrs[:classification] = inherit_classification(attrs)
              CapturedEvent.create!(attrs)
            end
          rescue StandardError => e
            log_capture_error(e)
          end

          # Capture an HTTP response processed by the adaptive response_parser.
          #
          # @param registry_name [Symbol, String] the registered limit name
          # @param response [Object] the raw response object
          # @param parsed [Hash] the parsed header data (remaining:, reset:, etc.)
          def capture_response(registry_name, response, parsed, adaptive_rate: nil)
            attrs = {
              registry_name: registry_name.to_s,
              event_type: "response",
              adaptive_rate: adaptive_rate
            }

            extract_response_attrs(attrs, response)
            extract_parsed_attrs(attrs, parsed)
            attrs[:classification] = inherit_classification(attrs)

            with_connection { CapturedEvent.create!(attrs) }
          rescue StandardError => e
            log_capture_error(e)
          end

          private

          def with_connection(&)
            ActiveRecord::Base.connection_pool.with_connection(&)
          end

          # Look up the most recent event with the same group key
          # (registry, type, exception_class, response_status) and reuse
          # its classification. Falls back to UNCLASSIFIED for new groups.
          def inherit_classification(attrs)
            existing = CapturedEvent.where(
              registry_name: attrs[:registry_name],
              event_type: attrs[:event_type],
              exception_class: attrs[:exception_class],
              response_status: attrs[:response_status]
            ).where.not(classification: CapturedEvent::UNCLASSIFIED)
              .order(created_at: :desc).pick(:classification)

            existing || CapturedEvent::UNCLASSIFIED
          end

          def extract_response_attrs(attrs, response)
            attrs[:response_status] = extract_status(response)
            attrs[:response_headers] = extract_headers(response)
            attrs[:response_body_snippet] = extract_body_snippet(response)
            extract_request_context(attrs, response)
          end

          def extract_request_context(attrs, response)
            method, url = request_context_from(response)
            attrs[:http_method] = method
            attrs[:request_url] = url
          end

          def request_context_from(response)
            return env_request_context(response) if response.respond_to?(:env)
            return hash_request_context(response) if response.is_a?(Hash)

            [nil, nil]
          end

          def env_request_context(response)
            [response.env[:method]&.to_s&.upcase, response.env[:url]&.to_s&.truncate(2000)]
          end

          def hash_request_context(response)
            [response[:method]&.to_s&.upcase, response[:url]&.to_s&.truncate(2000)]
          end

          def extract_status(response)
            return response[:status] if response.is_a?(Hash) && response.key?(:status)

            safe_call(response, :status)
          end

          def safe_call(obj, method)
            obj.respond_to?(method) ? obj.public_send(method) : nil
          end

          def extract_parsed_attrs(attrs, parsed)
            return unless parsed.is_a?(Hash)

            attrs[:response_status] ||= parsed[:status]
          end

          def extract_headers(response)
            headers = raw_headers_from(response)
            return nil unless headers

            (headers.is_a?(String) ? headers : headers.to_json).truncate(4000)
          end

          def raw_headers_from(response)
            if response.is_a?(Hash) && response.key?(:headers)
              response[:headers]
            elsif response.respond_to?(:headers)
              response.headers.to_h
            elsif response.respond_to?(:[]) && response.respond_to?(:each_header)
              {}.tap { |h| response.each_header { |k, v| h[k] = v } }
            end
          end

          def extract_body_snippet(response)
            body = if response.is_a?(Hash) && response.key?(:body)
                     response[:body]
                   elsif response.respond_to?(:body)
                     response.body
                   end
            body&.to_s&.truncate(1000)
          end

          def log_capture_error(error)
            msg = "[HanikamuRateLimit::EventCapture] #{error.class}: #{error.message}"
            if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
              Rails.logger.error(msg)
            else
              warn msg
            end
          end
        end
      end
    end
  end
end
