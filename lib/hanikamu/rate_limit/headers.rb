# frozen_string_literal: true

require "json"
require "redis"

module Hanikamu
  module RateLimit
    module Headers
      class << self
        def capture!(headers:, registry: nil, redis_key: nil, rate: nil, interval: nil, key_prefix: nil,
                     klass_name: nil, method: nil, header_names: nil, check_interval: nil,
                     max_wait_time: nil)
          config = registry ? Hanikamu::RateLimit.fetch_limit(registry) : {}

          rate ||= config[:rate]
          interval ||= config[:interval]
          key_prefix ||= config[:key_prefix]
          header_names = resolve_header_names(header_names, config)
          check_interval ||= config[:check_interval]
          max_wait_time ||= config[:max_wait_time]

          redis_key ||= build_redis_key(key_prefix, rate, interval, klass_name, method, registry)
          captured = capture_from_headers(headers, header_names)
          return if captured.empty?

          persist_observation(
            redis_key: redis_key,
            captured: captured,
            rate: rate,
            interval: interval,
            klass_name: klass_name,
            method: method,
            key_prefix: key_prefix,
            check_interval: check_interval,
            max_wait_time: max_wait_time,
            headers_config: header_names
          )
        end

        private

        def resolve_header_names(header_names, config)
          return header_names unless header_names.nil?
          return config[:headers] unless config[:headers].nil?

          Hanikamu::RateLimit.config.rate_limit_headers
        end

        def build_redis_key(key_prefix, rate, interval, klass_name, method, registry)
          return nil if rate.nil? || interval.nil?

          prefix = key_prefix
          if prefix.nil? && klass_name && method
            prefix = "#{RateQueue::KEY_PREFIX}:#{klass_name}:#{method}"
          end
          prefix ||= "#{RateQueue::KEY_PREFIX}:manual:#{registry || "custom"}"

          "#{prefix}:#{rate}:#{interval}"
        end

        def capture_from_headers(headers, header_names)
          headers_hash = normalize_headers(headers)
          return {} if headers_hash.empty?

          if header_names.nil? || (header_names.respond_to?(:empty?) && header_names.empty?)
            return headers_hash
          end

          return select_header_values(headers_hash, header_names) if header_names.is_a?(Array)

          {}
        end

        def normalize_headers(headers)
          hash = if headers.is_a?(Hash)
                   headers
                 elsif headers.respond_to?(:to_hash)
                   headers.to_hash
                 else
                   {}
                 end

          hash.each_with_object({}) do |(key, value), acc|
            acc[key.to_s] = value
          end
        end

        def select_header_values(headers, names)
          normalized = headers.each_with_object({}) do |(key, value), acc|
            acc[key.to_s.downcase] = value
          end

          names.each_with_object({}) do |name, acc|
            value = normalized[name.to_s.downcase]
            acc[name.to_s] = value unless value.nil?
          end
        end

        def persist_observation(redis_key:, captured:, rate:, interval:, klass_name:, method:, key_prefix:,
                                check_interval:, max_wait_time:, headers_config:)
          headers_config_json = headers_config.nil? ? nil : JSON.generate(headers_config)
          payload = {
            "observed_at" => Time.now.to_i,
            "rate" => rate,
            "interval" => interval,
            "klass_name" => klass_name,
            "method" => method,
            "key_prefix" => key_prefix,
            "redis_key" => redis_key,
            "check_interval" => check_interval,
            "max_wait_time" => max_wait_time,
            "headers_config" => headers_config_json
          }.compact.merge(captured.transform_keys(&:to_s))

          redis = Redis.new(url: Hanikamu::RateLimit.config.redis_url)
          prefix = Hanikamu::RateLimit.config.observations_key_prefix
          key = "#{prefix}:#{redis_key}"

          redis.hset(key, payload)
          redis.sadd("#{prefix}:keys", key)
        end
      end
    end
  end
end
