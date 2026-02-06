# frozen_string_literal: true

require "securerandom"
require "redis"
require "json"

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
        @headers = options.fetch(:headers, Hanikamu::RateLimit.config.rate_limit_headers)
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

      def record(result)
        captured = capture_headers(result)
        return if captured.empty?

        persist_observation(captured)
      rescue Redis::BaseError => e
        warn "[Hanikamu::RateLimit] Redis error: #{e.class} - #{e.message}"
        nil
      rescue StandardError => e
        warn "[Hanikamu::RateLimit] Header capture error: #{e.class} - #{e.message}"
        nil
      end

      private

      def redis_key
        @redis_key ||= begin
          prefix = @key_prefix || "#{KEY_PREFIX}:#{@klass_name}:#{@method}"
          "#{prefix}:#{@rate}:#{@interval}"
        end
      end

      def capture_headers(result)
        if @headers.nil? || (@headers.respond_to?(:empty?) && @headers.empty?)
          headers = extract_headers(result)
          return normalize_headers(headers)
        end

        if @headers.is_a?(Array)
          headers = extract_headers(result)
          return select_header_values(headers, @headers)
        end

        if @headers.is_a?(Hash)
          source = extract_nested_source(result)
          return select_nested_values(source, @headers)
        end

        {}
      end

      def extract_headers(result)
        return result[:headers] || result["headers"] if result.is_a?(Hash)
        return result.headers if result.respond_to?(:headers)
        return result.to_hash if result.respond_to?(:to_hash)

        nil
      end

      def select_header_values(headers, names)
        return {} unless headers.is_a?(Hash)

        normalized = headers.each_with_object({}) do |(key, value), acc|
          acc[key.to_s.downcase] = value
        end

        names.each_with_object({}) do |name, acc|
          value = normalized[name.to_s.downcase]
          acc[name.to_s] = value unless value.nil?
        end
      end

      def normalize_headers(headers)
        return {} unless headers.is_a?(Hash)

        headers.each_with_object({}) do |(key, value), acc|
          acc[key.to_s] = value
        end
      end

      def extract_nested_source(result)
        return result if result.is_a?(Hash)
        return result.to_h if result.respond_to?(:to_h)

        nil
      end

      def select_nested_values(source, mapping, prefix = nil, acc = {})
        return acc unless source.is_a?(Hash)

        mapping.each do |key, value|
          nested = dig_value(source, key)
          if value.is_a?(Hash)
            select_nested_values(nested, value, join_path(prefix, key), acc)
          elsif value.is_a?(Array)
            acc.merge!(select_header_values(nested, value).transform_keys { |k| join_path(prefix, key, k) })
          else
            acc[join_path(prefix, key)] = nested unless nested.nil?
          end
        end

        acc
      end

      def dig_value(source, key)
        return source[key] if source.key?(key)
        return source[key.to_s] if source.key?(key.to_s)
        return source[key.to_sym] if source.key?(key.to_sym)

        nil
      end

      def join_path(*parts)
        parts.compact.map(&:to_s).join(".")
      end

      def persist_observation(captured)
        key = observation_key
        headers_config = @headers.nil? ? nil : JSON.generate(@headers)
        payload = {
          "observed_at" => Time.now.to_i,
          "rate" => @rate,
          "interval" => @interval,
          "klass_name" => @klass_name,
          "method" => @method,
          "key_prefix" => @key_prefix,
          "redis_key" => redis_key,
          "check_interval" => @check_interval,
          "max_wait_time" => @max_wait_time,
          "headers_config" => headers_config
        }.merge(captured.transform_keys(&:to_s))

        redis.hset(key, payload)
        redis.sadd(observation_index_key, key)
      end

      def observation_key
        "#{observations_key_prefix}:#{redis_key}"
      end

      def observation_index_key
        "#{observations_key_prefix}:keys"
      end

      def observations_key_prefix
        Hanikamu::RateLimit.config.observations_key_prefix
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
