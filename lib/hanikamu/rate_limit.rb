# frozen_string_literal: true

require "dry/configurable"
require "dry/container"
require "hanikamu/rate_limit/errors"
require "hanikamu/rate_limit/mixin"
require "hanikamu/rate_limit/metrics"
require "hanikamu/rate_limit/rate_queue"
require "hanikamu/rate_limit/ui"
require "hanikamu/rate_limit/version"

module Hanikamu
  module RateLimit
    extend Dry::Configurable

    setting :redis_url
    setting :max_wait_time, default: 2.0
    setting :check_interval, default: 0.5
    setting :metrics_enabled, default: false
    setting :metrics_bucket_seconds, default: 300
    setting :metrics_window_seconds, default: 86_400
    setting :metrics_realtime_bucket_seconds, default: 1
    setting :metrics_realtime_window_seconds, default: 300
    setting :ui_auth
    setting :ui_max_sse_connections, default: 10

    class << self
      def configure(&block)
        super do |config|
          install_register_limit_helper(config)
          block&.call(config)
        end
      end

      def register_limit(name, rate:, interval:, check_interval: nil, max_wait_time: nil, metrics: nil)
        registry.register(
          normalize_name(name),
          normalize_registry_options(
            name, rate: rate, interval: interval,
                  check_interval: check_interval, max_wait_time: max_wait_time, metrics: metrics
          )
        )
      end

      def fetch_limit(name)
        registry.resolve(normalize_name(name))
      rescue Dry::Container::Error, KeyError
        raise ArgumentError, "Unknown registered limit: #{name}"
      end

      def register_temporary_limit(name, remaining:, reset:)
        cfg = fetch_limit(name) # raise if not registered
        remaining_value = Integer(remaining, exception: false)
        reset_value = Integer(reset, exception: false)
        return false if remaining_value.nil? || reset_value.nil?
        return false if remaining_value.negative? || reset_value <= 0

        key = override_key_for(name)
        redis_client.set(key, remaining_value, ex: reset_value)

        metrics_flag = cfg[:metrics]
        effective_metrics = metrics_flag.nil? ? config.metrics_enabled : metrics_flag
        Metrics.record_override(normalize_name(name), remaining_value, reset_value) if effective_metrics
        true
      end

      def metrics_snapshot
        Metrics.dashboard_payload
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

      def install_register_limit_helper(config)
        config.define_singleton_method(:register_limit) do |name, rate:, interval:,
                                                            check_interval: nil, max_wait_time: nil, metrics: nil|
          Hanikamu::RateLimit.register_limit(
            name, rate: rate, interval: interval,
                  check_interval: check_interval, max_wait_time: max_wait_time, metrics: metrics
          )
        end
      end

      def normalize_name(name)
        normalized = name.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_+|_+$/, "")
        normalized.to_sym
      end

      def redis_client
        @redis_client ||= Redis.new(url: config.redis_url)
      end

      def normalize_registry_options(name, rate:, interval:, check_interval:, max_wait_time:, metrics:)
        normalized = normalize_name(name)
        key_prefix = "#{RateQueue::KEY_PREFIX}:registry:#{normalized}"
        registry_options = { rate: rate, interval: interval, key_prefix: key_prefix }
        registry_options[:check_interval] = check_interval unless check_interval.nil?
        registry_options[:max_wait_time] = max_wait_time unless max_wait_time.nil?
        registry_options[:metrics] = metrics unless metrics.nil?
        registry_options
      end
    end
  end
end
