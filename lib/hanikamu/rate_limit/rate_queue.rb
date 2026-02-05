# frozen_string_literal: true

require "securerandom"
require "redis"

module Hanikamu
  module RateLimit
    class RateQueue
      KEY_PREFIX = "hanikamu:rate_limit:rate_queue"
      LUA_SCRIPT = <<~LUA
        local key = KEYS[1]
        local now = tonumber(ARGV[1])
        local interval = tonumber(ARGV[2])
        local rate = tonumber(ARGV[3])
        local member = ARGV[4]

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

      def initialize(rate, klass_name:, method:, interval: 60, **options, &block)
        @rate = rate
        @interval = interval.to_f
        @klass_name = klass_name
        @method = method
        @key_prefix = options[:key_prefix]
        @check_interval = options.fetch(:check_interval, Hanikamu::RateLimit.config.check_interval)
        @max_wait_time = options.fetch(:max_wait_time, Hanikamu::RateLimit.config.max_wait_time)
        @block = block
      end

      def shift
        start_time = current_time

        loop do
          allowed, sleep_time = attempt_shift(start_time)

          return if allowed == 1

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

      def redis_key
        @redis_key ||= begin
          prefix = @key_prefix || "#{KEY_PREFIX}:#{@klass_name}:#{@method}"
          "#{prefix}:#{@rate}:#{@interval}"
        end
      end

      def attempt_shift(start_time)
        now = current_time
        elapsed = now - start_time
        if @max_wait_time && elapsed > @max_wait_time
          raise Hanikamu::RateLimit::RateLimitError, "Max wait time exceeded"
        end

        member = "#{now}-#{SecureRandom.uuid}"
        eval_script(now, member)
      end

      def eval_script(now, member)
        redis.evalsha(
          lua_sha,
          keys: [redis_key],
          argv: [now, @interval, @rate, member]
        )
      rescue Redis::CommandError => e
        return reload_script_and_retry(now, member) if e.message.include?("NOSCRIPT")

        raise
      end

      def reload_script_and_retry(now, member)
        @lua_sha = redis.script(:load, LUA_SCRIPT)
        redis.evalsha(
          lua_sha,
          keys: [redis_key],
          argv: [now, @interval, @rate, member]
        )
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
