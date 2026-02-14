# frozen_string_literal: true

require "securerandom"
require "redis"

module Hanikamu
  module RateLimit
    class RateQueue
      KEY_PREFIX = "hanikamu:rate_limit:rate_queue"
      LUA_SCRIPT = <<~LUA
        local key = KEYS[1]
        local override_key = KEYS[2]
        local now = tonumber(ARGV[1])
        local interval = tonumber(ARGV[2])
        local rate = tonumber(ARGV[3])
        local member = ARGV[4]

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

        redis.call("ZREMRANGEBYSCORE", key, 0, now - interval)
        local count = redis.call("ZCARD", key)

        if count < rate then
          redis.call("ZADD", key, now, member)
          redis.call("EXPIRE", key, math.ceil(interval) + 1)
          return {1, 0}
        end

        local oldest = redis.call("ZRANGE", key, 0, 0, "WITHSCORES")
        if oldest and oldest[2] then
          local sleep_for = tonumber(oldest[2]) + interval - now
          if sleep_for < 0 then sleep_for = 0 end
          return {0, sleep_for}
        end

        return {0, interval}
      LUA

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
        &block
      )
        @rate = rate
        @interval = interval.to_f
        @klass_name = klass_name
        @method = method
        @key_prefix = key_prefix
        @override_key = override_key&.to_s
        @check_interval = check_interval.nil? ? Hanikamu::RateLimit.config.check_interval : check_interval
        @max_wait_time = max_wait_time.nil? ? Hanikamu::RateLimit.config.max_wait_time : max_wait_time
        @block = block
        setup_metrics(metrics)
      end

      def shift
        start_time = current_time
        override_recorded = false
        loop do
          allowed, sleep_time, is_override = attempt_shift(start_time)
          return record_and_return_allowed if allowed == 1

          if is_override == 1
            handle_override_rejection(sleep_time, record: !override_recorded)
            override_recorded = true
          end

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

      def handle_override_rejection(sleep_time, record: true)
        if record && @metrics_enabled && @metrics_registry
          Hanikamu::RateLimit::Metrics.record_override(@metrics_registry, 0, sleep_time.to_i)
        end

        return unless @max_wait_time && sleep_time.to_f > @max_wait_time

        Hanikamu::RateLimit::Metrics.record_blocked(redis_key) if @metrics_enabled
        raise Hanikamu::RateLimit::RateLimitError, "Max wait time exceeded"
      end

      def redis_key
        @redis_key ||= begin
          prefix = @key_prefix || "#{KEY_PREFIX}:#{@klass_name}:#{@method}"
          "#{prefix}:#{@rate}:#{@interval}"
        end
      end

      def redis_keys
        return [redis_key] if @override_key.nil? || @override_key.empty?

        [redis_key, @override_key]
      end

      def attempt_shift(start_time)
        now = current_time
        elapsed = now - start_time
        if @max_wait_time && elapsed > @max_wait_time
          Hanikamu::RateLimit::Metrics.record_blocked(redis_key) if @metrics_enabled
          raise Hanikamu::RateLimit::RateLimitError, "Max wait time exceeded"
        end

        member = "#{now}-#{SecureRandom.uuid}"
        eval_script(now, member)
      end

      def eval_script(now, member)
        redis.evalsha(lua_sha, keys: redis_keys, argv: [now, @interval, @rate, member])
      rescue Redis::CommandError => e
        return reload_script_and_retry(now, member) if e.message.include?("NOSCRIPT")

        raise
      end

      def reload_script_and_retry(now, member)
        @lua_sha = redis.script(:load, LUA_SCRIPT)
        redis.evalsha(lua_sha, keys: redis_keys, argv: [now, @interval, @rate, member])
      end

      def handle_sleep(sleep_time)
        @block&.call(sleep_time)
        actual_sleep = @check_interval ? [@check_interval, sleep_time].min : sleep_time
        sleep(actual_sleep) if actual_sleep.to_f.positive?
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
    end
  end
end
