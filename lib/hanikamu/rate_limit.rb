# frozen_string_literal: true

require "dry/configurable"
require "dry/container"
require "hanikamu/rate_limit/adaptive_state"
require "hanikamu/rate_limit/errors"
require "hanikamu/rate_limit/job_retry"
require "hanikamu/rate_limit/mixin"
require "hanikamu/rate_limit/metrics"
require "hanikamu/rate_limit/rate_queue"
require "hanikamu/rate_limit/reset_ttl_resolver"
require "hanikamu/rate_limit/storage"
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
    setting :event_retention, default: 604_800   # seconds to keep captured events (default 7 days)
    setting :snapshot_interval, default: 30      # seconds between rate snapshots for adaptive limits
    setting :snapshot_retention, default: 86_400 # seconds to keep rate snapshots (default 24 hours)

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

      # Registers an adaptive (AIMD) limit. The rate starts at initial_rate
      # and adjusts automatically based on success/error feedback.
      # Stored in the same registry as fixed limits; the Mixin detects the
      # :adaptive flag and installs the appropriate wrapper.
      #
      # Shorthand: pass `rate: 10..100` as the first two params to auto-derive
      # initial_rate (midpoint), min_rate, max_rate, and sensible AIMD defaults.
      #
      #   register_adaptive_limit(:api, rate: 10..100, interval: 1.0)
      #
      def register_adaptive_limit(name, interval:, rate: nil, initial_rate: nil,
                                  min_rate: nil, max_rate: nil,
                                  increase_by: nil, decrease_factor: nil,
                                  probe_window: nil, cooldown_after_decrease: nil,
                                  utilization_threshold: nil, ceiling_threshold: nil,
                                  error_classes: [], header_parser: nil,
                                  response_parser: nil,
                                  check_interval: nil, max_wait_time: nil, metrics: nil)
        tuning = build_tuning_hash(initial_rate: initial_rate, min_rate: min_rate, max_rate: max_rate,
                                   increase_by: increase_by, decrease_factor: decrease_factor,
                                   probe_window: probe_window, cooldown_after_decrease: cooldown_after_decrease,
                                   utilization_threshold: utilization_threshold, ceiling_threshold: ceiling_threshold)
        opts = resolve_adaptive_opts(rate, tuning)
        register_adaptive_limit_from_opts(
          name, interval: interval, error_classes: error_classes,
                header_parser: header_parser, response_parser: response_parser,
                check_interval: check_interval, max_wait_time: max_wait_time, metrics: metrics,
                **opts
        )
      end

      # Returns (or lazily creates) the AdaptiveState for a named adaptive limit.
      def fetch_adaptive_state(name)
        normalized = normalize_name(name)
        adaptive_states[normalized] ||= begin
          cfg = fetch_limit(name)
          raise ArgumentError, "#{name} is not an adaptive limit" unless cfg[:adaptive]

          AdaptiveState.new(normalized, cfg)
        end
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
        @adaptive_states = {}
      end

      # Deletes both the sliding-window sorted set and the override key from Redis,
      # allowing the quota to start completely fresh.
      # For adaptive limits, also resets the learned AIMD state.
      def reset_limit!(name)
        cfg = fetch_limit(name)
        key_prefix = cfg.fetch(:key_prefix)
        interval = cfg.fetch(:interval)

        # Adaptive limits exclude rate from the key; fixed limits include it.
        limit_key = if cfg[:adaptive]
                      "#{key_prefix}:#{interval.to_f}"
                    else
                      "#{key_prefix}:#{cfg.fetch(:rate)}:#{interval.to_f}"
                    end

        redis_client.del(limit_key, override_key_for(name))
        fetch_adaptive_state(name).reset! if cfg[:adaptive]
        true
      end

      def registry
        @registry ||= Dry::Container.new
      end

      def adaptive_states
        @adaptive_states ||= {}
      end

      private

      # Defines register_limit and register_adaptive_limit as singleton methods
      # on the config object so they can be called inside the configure block.
      def install_register_limit_helper(config)
        config.define_singleton_method(:register_limit) do |name, rate:, interval:,
                                                            check_interval: nil, max_wait_time: nil, metrics: nil|
          Hanikamu::RateLimit.register_limit(
            name, rate: rate, interval: interval,
                  check_interval: check_interval, max_wait_time: max_wait_time, metrics: metrics
          )
        end

        config.define_singleton_method(:register_adaptive_limit) do |name, **opts|
          Hanikamu::RateLimit.register_adaptive_limit(name, **opts)
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

      # Internal: registers an adaptive limit after options have been resolved
      # (either from explicit params or from a Range expansion).
      def register_adaptive_limit_from_opts(name, interval:, error_classes:,
                                            header_parser:, response_parser:,
                                            check_interval:, max_wait_time:, metrics:, **aimd)
        validate_adaptive_options!(aimd.merge(interval: interval))
        opts = normalize_registry_options(
          name, rate: aimd[:initial_rate], interval: interval,
                check_interval: check_interval, max_wait_time: max_wait_time, metrics: metrics
        ).merge(
          adaptive: true,
          error_classes: Array(error_classes), header_parser: header_parser,
          response_parser: response_parser,
          **aimd
        )
        registry.register(normalize_name(name), opts)
      end

      # Builds explicit AIMD options from individual params (non-Range path).
      def explicit_adaptive_options(rate, **overrides)
        defaults = { initial_rate: rate, min_rate: 1, max_rate: nil,
                     increase_by: 1, decrease_factor: 0.5,
                     probe_window: 60, cooldown_after_decrease: 30,
                     utilization_threshold: 0.7, ceiling_threshold: 0.9 }
        defaults.merge(overrides) { |_key, default, override| override || default }
      end

      # Collects the AIMD tuning keyword args into a single hash.
      def build_tuning_hash(**kwargs)
        kwargs
      end

      # Dispatches to range or explicit adaptive option builder.
      def resolve_adaptive_opts(rate, tuning)
        if rate.is_a?(Range)
          expand_range_adaptive_options(rate, **tuning)
        else
          explicit_adaptive_options(rate, **tuning)
        end
      end

      # Expands a Range (e.g. 10..100) into explicit AIMD parameters.
      # initial_rate = midpoint, with sensible tuning defaults derived from the range width.
      def expand_range_adaptive_options(range, **overrides)
        validate_range!(range)
        defaults = range_defaults(range)
        defaults.merge(overrides) { |_key, default, override| override || default }
      end

      def validate_range!(range)
        low = range.min
        high = range.max
        return if low.is_a?(Integer) && high.is_a?(Integer) && low < high

        raise ArgumentError, "rate range must have min < max"
      end

      def range_defaults(range)
        low  = range.min
        high = range.max
        mid  = ((low + high) / 2.0).ceil
        span = high - low
        { initial_rate: mid, min_rate: low, max_rate: high,
          increase_by: [span / 20, 1].max, decrease_factor: 0.5,
          probe_window: 60, cooldown_after_decrease: 30,
          utilization_threshold: 0.7, ceiling_threshold: 0.9 }
      end

      def validate_adaptive_options!(opts) # rubocop:disable Metrics/AbcSize
        validate_positive_integer!(:initial_rate, opts[:initial_rate])
        validate_positive_numeric!(:interval, opts[:interval])
        validate_positive_integer!(:min_rate, opts[:min_rate])
        raise ArgumentError, "min_rate must be <= initial_rate" if opts[:min_rate] > opts[:initial_rate]

        if opts[:max_rate] && opts[:max_rate] < opts[:initial_rate]
          raise ArgumentError,
                "max_rate must be >= initial_rate"
        end

        validate_unit_fraction!(:decrease_factor, opts[:decrease_factor])
        validate_positive_numeric!(:increase_by, opts[:increase_by])
        validate_positive_numeric!(:probe_window, opts[:probe_window])
        validate_positive_numeric!(:cooldown_after_decrease, opts[:cooldown_after_decrease])
      end

      def validate_positive_integer!(label, value)
        return if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "#{label} must be a positive Integer"
      end

      def validate_positive_numeric!(label, value)
        return if value.is_a?(Numeric) && value.positive?

        raise ArgumentError, "#{label} must be a positive Numeric"
      end

      def validate_unit_fraction!(label, value)
        return if value.is_a?(Numeric) && value.positive? && value < 1

        raise ArgumentError, "#{label} must be between 0 and 1 (exclusive)"
      end
    end
  end
end
