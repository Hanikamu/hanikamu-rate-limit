# frozen_string_literal: true

require "dry/configurable"
require "dry/container"
require "hanikamu/rate_limit/errors"
require "hanikamu/rate_limit/job_retry"
require "hanikamu/rate_limit/mixin"
require "hanikamu/rate_limit/metrics"
require "hanikamu/rate_limit/rate_queue"
require "hanikamu/rate_limit/reset_ttl_resolver"
require "hanikamu/rate_limit/ui"
require "hanikamu/rate_limit/version"

module Hanikamu
  # Top-level module for distributed rate limiting.
  #
  # Provides a Redis-backed sliding window algorithm that coordinates throughput
  # across multiple processes and threads. Limits are enforced atomically via a
  # Lua script executed inside Redis (see RateQueue::LUA_SCRIPT).
  #
  # Two usage modes:
  #   1. Inline  — pass rate:/interval: directly on limit_method (per-class key).
  #   2. Registry — register a named limit once, reference it by name across classes
  #                 (shared Redis key).
  #
  # Configuration uses dry-configurable; the registry uses dry-container.
  module RateLimit # rubocop:disable Metrics/ModuleLength
    extend Dry::Configurable

    setting :redis_url
    setting :max_wait_time, default: 2.0          # seconds — give up and raise RateLimitError after this
    setting :check_interval, default: 0.5         # seconds — polling interval when waiting for a slot
    setting :metrics_enabled, default: false       # must be true for the UI dashboard to work
    setting :metrics_bucket_seconds, default: 300  # histogram bucket size for 24-hour chart
    setting :metrics_window_seconds, default: 86_400         # rolling window for 24-hour chart
    setting :metrics_realtime_bucket_seconds, default: 1     # bucket size for 5-minute chart
    setting :metrics_realtime_window_seconds, default: 300   # rolling window for 5-minute chart
    setting :wait_strategy, default: :sleep  # :sleep blocks thread; :raise raises RateLimitError immediately
    setting :jitter, default: 0.0            # proportional random spread: wait + rand * jitter * wait
    setting :ui_auth                         # callable for dashboard auth — deny-by-default when nil
    setting :ui_max_sse_connections, default: 10 # cap concurrent SSE connections to prevent thread exhaustion

    class << self
      # Extends Dry::Configurable's configure to inject a register_limit helper
      # onto the config object, so users can call config.register_limit(...)
      # inside the configure block for convenience.
      def configure(&block)
        super do |config|
          install_register_limit_helper(config)
          block&.call(config)
        end
      end

      # Stores a named limit in the Dry::Container registry.
      # The key_prefix is derived automatically from the normalized name,
      # ensuring all classes using the same registry name share one Redis key.
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

      # Creates a temporary fixed-window override backed by a Redis key with a TTL.
      # While active, the Lua script checks this key first: if remaining > 0 it
      # decrements and allows; if remaining == 0 it rejects with the key's TTL as
      # the sleep duration. When the TTL expires the key vanishes and the sliding
      # window resumes automatically.
      #
      # reset_kind controls how the reset: value is interpreted:
      #   :seconds  — used directly as Redis EX (TTL in seconds); capped at 86,400
      #   :unix     — Unix epoch timestamp; converted to seconds-from-now
      #   :datetime — Time/DateTime object; converted to seconds-from-now
      #
      # Returns true on success, false if the values are invalid/unparseable.
      def register_temporary_limit(name, remaining:, reset:, reset_kind: :seconds)
        cfg = fetch_limit(name) # raise if not registered
        remaining_value = Integer(Array(remaining).first, exception: false)
        ttl = ResetTtlResolver.resolve(reset, reset_kind)
        return false if remaining_value.nil? || ttl.nil?
        return false if remaining_value.negative? || ttl <= 0

        key = override_key_for(name)
        redis_client.set(key, remaining_value, ex: ttl)
        record_override_metrics(cfg, name, remaining_value, ttl)
        true
      end

      def metrics_snapshot
        Metrics.dashboard_payload
      end

      # Thread-local override for the wait strategy. Scoped to the block;
      # restores the previous value on exit (even on exceptions).
      # Used by JobRetry to set :raise for the duration of a job without
      # affecting other threads or the global config.
      def with_wait_strategy(strategy)
        previous = Thread.current[:hanikamu_rate_limit_wait_strategy]
        Thread.current[:hanikamu_rate_limit_wait_strategy] = strategy
        yield
      ensure
        Thread.current[:hanikamu_rate_limit_wait_strategy] = previous
      end

      def current_wait_strategy
        Thread.current[:hanikamu_rate_limit_wait_strategy]
      end

      def override_key_for(name)
        normalized = normalize_name(name)
        "#{RateQueue::KEY_PREFIX}:registry:#{normalized}:override"
      end

      def reset_registry!
        @registry = Dry::Container.new
      end

      # Deletes both the sliding-window sorted set and the override key from Redis,
      # allowing the quota to start completely fresh.
      def reset_limit!(name)
        cfg = fetch_limit(name)
        key_prefix = cfg.fetch(:key_prefix)
        rate = cfg.fetch(:rate)
        interval = cfg.fetch(:interval)
        limit_key = "#{key_prefix}:#{rate}:#{interval.to_f}"

        redis_client.del(limit_key, override_key_for(name))
        true
      end

      def registry
        @registry ||= Dry::Container.new
      end

      private

      # Defines register_limit as a singleton method on the config object so it
      # can be called inside the configure block: config.register_limit(:name, ...)
      def install_register_limit_helper(config)
        config.define_singleton_method(:register_limit) do |name, rate:, interval:,
                                                            check_interval: nil, max_wait_time: nil, metrics: nil|
          Hanikamu::RateLimit.register_limit(
            name, rate: rate, interval: interval,
                  check_interval: check_interval, max_wait_time: max_wait_time, metrics: metrics
          )
        end
      end

      # Normalizes limit names to lowercase snake_case symbols.
      # "External Api" → :external_api, :ExternalApi → :externalapi
      def normalize_name(name)
        normalized = name.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_+|_+$/, "")
        normalized.to_sym
      end

      # Single Redis connection reused across all register_temporary_limit calls.
      # Separate from the per-RateQueue connections (each queue has its own).
      def redis_client
        @redis_client ||= Redis.new(url: config.redis_url)
      end

      # Respects the per-limit metrics override, falling back to the global setting.
      def record_override_metrics(cfg, name, remaining_value, reset_value)
        metrics_flag = cfg[:metrics]
        effective = metrics_flag.nil? ? config.metrics_enabled : metrics_flag
        Metrics.record_override(normalize_name(name), remaining_value, reset_value) if effective
      end

      # Builds the options hash stored in the registry for a named limit.
      # Derives key_prefix from the normalized name so all users of the same
      # registry share one Redis key (e.g. "hanikamu:rate_limit:...registry:external_api").
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
