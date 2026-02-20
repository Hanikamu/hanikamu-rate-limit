# frozen_string_literal: true

require "securerandom"
require "redis"

module Hanikamu
  module RateLimit
    # Core rate limiter backed by a Redis sorted set (sliding window) and an
    # optional override key (fixed-window counter with TTL).
    #
    # Algorithm:
    #   The Lua script (LUA_SCRIPT) runs atomically inside Redis on every call to #shift.
    #   It first checks for an active override key (from register_temporary_limit);
    #   if present and remaining > 0, it DECRs and allows immediately. If remaining == 0,
    #   it returns the key's TTL as sleep_time.
    #
    #   When no override is active (or the key has expired/is invalid), the script falls
    #   back to the sliding window: it removes entries older than `now - interval` from
    #   the sorted set, counts remaining members, and either adds the new request (allowed)
    #   or calculates how long to sleep based on the oldest entry's score.
    #
    # Waiting behaviour:
    #   - :sleep strategy — sleeps in check_interval steps until a slot opens or max_wait_time
    #     is exceeded, then raises RateLimitError.
    #   - :raise strategy — raises RateLimitError immediately with retry_after, freeing the
    #     thread for other work (used by JobRetry for background jobs).
    #
    # Fail-open:
    #   If Redis is unreachable, #shift logs a warning and returns nil (allows the request).
    class RateQueue
      KEY_PREFIX = "hanikamu:rate_limit:rate_queue"
      # Lua script executed atomically inside Redis via EVALSHA.
      # Two Redis keys are passed:
      #   KEYS[1] — the sliding window sorted set (score = timestamp, member = uuid)
      #   KEYS[2] — the override key (optional; simple string counter with EX/TTL)
      #
      # Returns an array [allowed, sleep_time, is_override?]:
      #   allowed    = 1 (proceed) or 0 (rate limited)
      #   sleep_time = seconds to wait before retrying
      #   is_override = 1 when the rejection came from the override key (used for metrics)
      LUA_SCRIPT = <<~LUA
        local key = KEYS[1]
        local override_key = KEYS[2]
        local now = tonumber(ARGV[1])
        local interval = tonumber(ARGV[2])
        local rate = tonumber(ARGV[3])
        local member = ARGV[4]

        -- Phase 1: Check override (fixed-window counter with TTL)
        -- If the override key exists and has a valid TTL, use it instead of the sliding window.
        -- DECR on allow; return TTL as sleep_time on reject.
        if override_key and override_key ~= "" then
          local override_val = redis.call("GET", override_key)
          if override_val then
            local remaining = tonumber(override_val)
            if remaining then
              local ttl = redis.call("TTL", override_key)
              if ttl > 0 then
                if remaining > 0 then
                  redis.call("DECR", override_key)
                  return {1, 0, 0}
                else
                  return {0, ttl, 1}
                end
              end
            end
          end
        end

        -- Phase 2: Sliding window algorithm
        -- Remove all entries older than (now - interval), then count remaining.
        redis.call("ZREMRANGEBYSCORE", key, 0, now - interval)
        local count = redis.call("ZCARD", key)

        -- Under the limit: add this request to the sorted set with score = now.
        -- The member is a unique "timestamp-uuid" string to avoid collisions.
        if count < rate then
          redis.call("ZADD", key, now, member)
          redis.call("EXPIRE", key, math.ceil(interval) + 1)
          return {1, 0}
        end

        -- Over the limit: calculate how long until the oldest entry expires.
        -- sleep_for = oldest_score + interval - now
        local oldest = redis.call("ZRANGE", key, 0, 0, "WITHSCORES")
        if oldest and oldest[2] then
          local sleep_for = tonumber(oldest[2]) + interval - now
          if sleep_for < 0 then sleep_for = 0 end
          return {0, sleep_for}
        end

        return {0, interval}
      LUA

      # Public readers used by AdaptiveState to check utilization.
      attr_reader :interval

      # Returns the Redis key for the sliding window sorted set.
      # Used by AdaptiveState#attach_sliding_window.
      def sliding_window_key
        redis_key
      end

      def initialize(
        rate,
        klass_name:,
        method:,
        interval: 60,
        key_prefix: nil,
        override_key: nil,
        check_interval: nil,
        max_wait_time: nil,
        metrics: nil,
        adaptive_state: nil,
        &block
      )
        @rate = rate
        @interval = interval.to_f
        @klass_name = klass_name
        @method = method
        @key_prefix = key_prefix
        @override_key = override_key&.to_s
        @adaptive_state = adaptive_state
        @check_interval = resolve_config_value(check_interval, :check_interval)
        @max_wait_time = resolve_config_value(max_wait_time, :max_wait_time)
        @block = block
        setup_metrics(metrics)
      end

      # Attempts to acquire a rate limit slot. Blocks (or raises) until allowed.
      # Returns nil on success (the method should proceed).
      # Raises RateLimitError if max_wait_time is exceeded or strategy is :raise.
      def shift
        state = { start_time: current_time, override_recorded: false, last_sleep_time: @interval }
        loop do
          allowed, sleep_time, is_override = attempt_shift(state[:start_time], state[:last_sleep_time])
          return record_and_return_allowed if allowed == 1

          state[:last_sleep_time] = sleep_time.to_f
          track_override(sleep_time, is_override, state)
          raise_if_strategy!(sleep_time)
          handle_sleep(sleep_time)
        end
      rescue Redis::BaseError => e
        warn "[Hanikamu::RateLimit] Redis error: #{e.class} - #{e.message}"
        nil
      end

      def reset
        redis.del(redis_key)
      end

      private

      def setup_metrics(metrics)
        @metrics_enabled = metrics.nil? ? Hanikamu::RateLimit.config.metrics_enabled : metrics
        prefix = @key_prefix || "#{KEY_PREFIX}:#{@klass_name}:#{@method}"
        @metrics_registry = Hanikamu::RateLimit::Metrics.registry_from_key_prefix(prefix)
        return unless @metrics_enabled

        Hanikamu::RateLimit::Metrics.record_registry_meta(
          redis_key, prefix, @rate, @interval, @klass_name, @method
        )
      end

      def record_and_return_allowed
        Hanikamu::RateLimit::Metrics.record_allowed(redis_key) if @metrics_enabled
        nil
      end

      # When an override rejection occurs (remaining == 0, TTL > 0):
      # - If TTL > max_wait_time, raise immediately (no point polling — the
      #   fixed-window won't reset until the TTL expires).
      # - Otherwise, let the loop continue polling until the override expires.
      def handle_override_rejection(sleep_time, record: true)
        if record && @metrics_enabled && @metrics_registry
          Hanikamu::RateLimit::Metrics.record_override(@metrics_registry, 0, sleep_time.to_i)
        end

        return unless sleep_time.to_f > @max_wait_time

        Hanikamu::RateLimit::Metrics.record_blocked(redis_key) if @metrics_enabled
        raise Hanikamu::RateLimit::RateLimitError.new("Max wait time exceeded", retry_after: sleep_time.to_f)
      end

      # Redis key for the sliding window sorted set.
      # For adaptive limits the rate is excluded because it changes at runtime;
      # for fixed limits it is included to isolate different configurations.
      def redis_key
        @redis_key ||= begin
          prefix = @key_prefix || "#{KEY_PREFIX}:#{@klass_name}:#{@method}"
          if @adaptive_state
            "#{prefix}:#{@interval}"
          else
            "#{prefix}:#{@rate}:#{@interval}"
          end
        end
      end

      # Keys passed to the Lua script. When no override_key is set,
      # only the sliding window key is passed (KEYS[2] will be nil in Lua).
      def redis_keys
        return [redis_key] if @override_key.nil? || @override_key.empty?

        [redis_key, @override_key]
      end

      # Checks elapsed time against max_wait_time, then runs the Lua script.
      # Each attempt generates a unique member (timestamp-uuid) for the sorted set.
      def attempt_shift(start_time, last_sleep_time)
        now = current_time
        elapsed = now - start_time
        if elapsed > @max_wait_time
          Hanikamu::RateLimit::Metrics.record_blocked(redis_key) if @metrics_enabled
          raise Hanikamu::RateLimit::RateLimitError.new("Max wait time exceeded", retry_after: last_sleep_time)
        end

        member = "#{now}-#{SecureRandom.uuid}"
        eval_script(now, member)
      end

      # Uses EVALSHA for efficiency; falls back to SCRIPT LOAD + retry on NOSCRIPT
      # (happens after Redis restarts or script cache eviction).
      def eval_script(now, member)
        redis.evalsha(lua_sha, keys: redis_keys, argv: [now, @interval, effective_rate, member])
      rescue Redis::CommandError => e
        return reload_script_and_retry(now, member) if e.message.include?("NOSCRIPT")

        raise
      end

      def reload_script_and_retry(now, member)
        @lua_sha = redis.script(:load, LUA_SCRIPT)
        redis.evalsha(lua_sha, keys: redis_keys, argv: [now, @interval, effective_rate, member])
      end

      # Sleeps for the shorter of check_interval and the jittered sleep_time.
      # Using check_interval as a cap means we poll at a fixed rate rather than
      # sleeping the full duration, allowing faster recovery when slots open.
      def handle_sleep(sleep_time)
        @block&.call(sleep_time)
        jittered = apply_jitter(sleep_time.to_f)
        actual_sleep = @check_interval ? [@check_interval, jittered].min : jittered
        sleep(actual_sleep) if actual_sleep.to_f.positive?
      end

      # When strategy is :raise, skip sleeping entirely and raise with retry_after.
      # This is the mechanism that makes JobRetry work: the job catches the error
      # and calls retry_job(wait: retry_after), freeing the worker thread.
      def raise_if_strategy!(sleep_time)
        return unless resolve_wait_strategy == :raise

        Hanikamu::RateLimit::Metrics.record_blocked(redis_key) if @metrics_enabled
        raise RateLimitError.new("Rate limited", retry_after: apply_jitter(sleep_time.to_f))
      end

      def track_override(sleep_time, is_override, state)
        return unless is_override == 1

        handle_override_rejection(sleep_time, record: !state[:override_recorded])
        state[:override_recorded] = true
      end

      # Adds proportional jitter: value + rand * jitter * value.
      # Prevents thundering herds when many workers are rate-limited simultaneously.
      # A jitter of 0.0 (default) disables this entirely.
      def apply_jitter(value)
        factor = Hanikamu::RateLimit.config.jitter.to_f
        return value if factor <= 0 || value <= 0

        value + (rand * factor * value)
      end

      def redis
        @redis ||= Redis.new(url: Hanikamu::RateLimit.config.redis_url)
      end

      def lua_sha
        @lua_sha ||= redis.script(:load, LUA_SCRIPT)
      end

      def current_time
        Time.now.to_f
      end

      # For adaptive limits, reads the current rate from the AdaptiveState
      # (backed by Redis with local caching). For fixed limits, returns @rate.
      def effective_rate
        @adaptive_state ? @adaptive_state.current_rate : @rate
      end

      # Thread-local strategy takes precedence over global config.
      # This is how JobRetry scopes :raise to a single job without affecting others.
      def resolve_wait_strategy
        Hanikamu::RateLimit.current_wait_strategy || Hanikamu::RateLimit.config.wait_strategy
      end

      def resolve_config_value(value, setting)
        value.nil? ? Hanikamu::RateLimit.config.public_send(setting) : value
      end
    end
  end
end
