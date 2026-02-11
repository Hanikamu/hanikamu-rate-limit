# frozen_string_literal: true

require "dry/configurable"
require "dry/container"
require "hanikamu/rate_limit/errors"
require "hanikamu/rate_limit/mixin"
require "hanikamu/rate_limit/rate_queue"
require "hanikamu/rate_limit/version"

module Hanikamu
  module RateLimit
    extend Dry::Configurable

    setting :redis_url
    setting :max_wait_time, default: 2.0
    setting :check_interval, default: 0.5

    class << self
      def configure(&block)
        super do |config|
          config.define_singleton_method(:register_limit) do |
            name,
            rate:,
            interval:,
            check_interval: nil,
            max_wait_time: nil
          |
            Hanikamu::RateLimit.register_limit(
              name,
              rate: rate,
              interval: interval,
              check_interval: check_interval,
              max_wait_time: max_wait_time
            )
          end
          block&.call(config)
        end
      end

      def register_limit(name, rate:, interval:, check_interval: nil, max_wait_time: nil)
        registry.register(
          normalize_name(name),
          normalize_registry_options(
            name,
            rate: rate,
            interval: interval,
            check_interval: check_interval,
            max_wait_time: max_wait_time
          )
        )
      end

      def fetch_limit(name)
        registry.resolve(normalize_name(name))
      rescue Dry::Container::Error, KeyError
        raise ArgumentError, "Unknown registered limit: #{name}"
      end

      def register_temporary_limit(name, remaining:, reset:)
        fetch_limit(name) # raise if not registered
        remaining_value = Integer(remaining, exception: false)
        reset_value = Integer(reset, exception: false)
        return false if remaining_value.nil? || reset_value.nil?
        return false if remaining_value.negative? || reset_value <= 0

        key = override_key_for(name)
        redis_client.set(key, remaining_value, ex: reset_value)
        true
      end

      def override_key_for(name)
        normalized = normalize_name(name)
        "#{RateQueue::KEY_PREFIX}:registry:#{normalized}:override"
      end

      def reset_registry!
        @registry = Dry::Container.new
      end

      def registry
        @registry ||= Dry::Container.new
      end

      private

      def normalize_name(name)
        normalized = name.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_+|_+$/, "")
        normalized.to_sym
      end

      def redis_client
        @redis_client ||= Redis.new(url: config.redis_url)
      end

      def normalize_registry_options(name, rate:, interval:, check_interval:, max_wait_time:)
        normalized = normalize_name(name)
        key_prefix = "#{RateQueue::KEY_PREFIX}:registry:#{normalized}"
        registry_options = { rate: rate, interval: interval, key_prefix: key_prefix }
        registry_options[:check_interval] = check_interval unless check_interval.nil?
        registry_options[:max_wait_time] = max_wait_time unless max_wait_time.nil?
        registry_options
      end
    end
  end
end
