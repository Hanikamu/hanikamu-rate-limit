# frozen_string_literal: true

require "redis"

module Hanikamu
  module RateLimit
    # Manages AIMD (Additive Increase, Multiplicative Decrease) state for
    # adaptive rate limits.
    #
    # State is persisted in Redis so it survives restarts and is shared across
    # processes. All mutations use Lua scripts for atomicity.
    #
    # The algorithm mirrors TCP congestion control:
    #   1. Start at initial_rate
    #   2. After probe_window seconds of success, increase by increase_by (additive)
    #   3. On error, multiply rate by decrease_factor (multiplicative decrease)
    #   4. Honour cooldown_after_decrease before probing again
    #   5. Converge just below the real limit over a few cycles
    #
    # Utilization awareness:
    #   The rate only increases when actual traffic (measured from the sliding
    #   window sorted set) exceeds utilization_threshold of the current rate.
    #   This prevents runaway increases during low-traffic periods.
    #
    # Error ceiling with confidence scoring:
    #   On every decrease, the pre-decrease rate is stored as an error ceiling
    #   and a hit counter is incremented.  The Learning UI can sync a
    #   "confidence" score (count of rate_limit-classified events) into Redis.
    #
    #   The dynamic ceiling threshold is:
    #     effective = base_ceiling_threshold
    #                 + (ceiling_hits × 0.02)
    #                 + (ceiling_confidence × 0.05)
    #
    #   More error occurrences = harder to break through the ceiling.
    #   Classified rate-limit events = even harder (3× per-hit penalty).
    #   Capped at 1.0, which effectively blocks increases past the ceiling.
    class AdaptiveState
      REDIS_PREFIX = "hanikamu:rate_limit:adaptive"

      # Local cache avoids a Redis GET on every rate-limited call.
      RATE_CACHE_TTL = 1.0

      # Per-hit caution penalty added to the ceiling threshold.
      HIT_PENALTY = 0.02

      # Per-classified-event caution penalty (stronger than hits alone).
      CONFIDENCE_PENALTY = 0.05

      attr_reader :name, :config

      def initialize(name, config)
        @name = name.to_sym
        @config = config
        @cached_rate = nil
        @cached_at = 0.0
        @sliding_window_key = nil
        @window_interval = nil
      end

      # Attach the RateQueue's sliding window key so the success Lua script
      # can check utilization before increasing.  Called once at setup time.
      def attach_sliding_window(key, interval)
        @sliding_window_key = key
        @window_interval = interval.to_f
      end

      # Returns the current adaptive rate, with local caching.
      def current_rate
        now = Time.now.to_f
        return @cached_rate if @cached_rate && (now - @cached_at) < RATE_CACHE_TTL

        rate = redis.get(rate_key)
        @cached_rate = rate ? rate.to_i : @config[:initial_rate]
        @cached_at = now
        @cached_rate
      end

      # Called after every successful method execution.
      # Atomically checks cooldown, probe window, utilization, and dynamic
      # ceiling, then increases if eligible.
      # Returns the new rate (> 0) on increase, 0 when skipped.
      def record_success!
        result = execute_lua(:success,
                             keys: success_keys,
                             argv: success_argv)
        invalidate_cache! if result.to_i.positive?
        result.to_i
      end

      # Called when an error_classes exception is caught or response_parser
      # signals decrease.
      # Atomically applies multiplicative decrease with min_rate floor,
      # records the pre-decrease rate as the error ceiling, and increments
      # the ceiling hit counter.
      # Returns the new rate.
      def decrease_rate!
        result = execute_lua(:decrease,
                             keys: [rate_key, cooldown_key,
                                    error_ceiling_key, ceiling_hits_key],
                             argv: [
                               @config[:decrease_factor],
                               @config[:min_rate],
                               @config[:initial_rate],
                               Time.now.to_f
                             ])
        invalidate_cache!
        result.to_i
      end

      # Processes an error: tries header_parser first, falls back to AIMD decrease.
      def handle_error(error, registry_name, header_parser)
        parsed = header_parser&.call(error)
        if parsed.is_a?(Hash) && parsed[:remaining]
          Hanikamu::RateLimit.register_temporary_limit(registry_name, **parsed)
        else
          decrease_rate!
        end
      end

      # Processes a successful response: extracts rate-limit headers via
      # response_parser and feeds them into register_temporary_limit.
      # Returns the parsed hash on success, nil otherwise.
      def handle_response(result, registry_name, response_parser)
        parsed = response_parser&.call(result)
        return nil unless parsed.is_a?(Hash) && parsed[:remaining]

        Hanikamu::RateLimit.register_temporary_limit(registry_name, **parsed)
        parsed
      end

      # Syncs the ceiling confidence from the database.
      # Called by the Learning UI after classification changes.
      # `count` is the number of rate_limit-classified events for this registry.
      def sync_ceiling_confidence!(count)
        redis.set(ceiling_confidence_key, [count.to_i, 0].max)
      end

      # Clears all persisted AIMD state; rate reverts to initial_rate.
      def reset!
        redis.del(rate_key, cooldown_key, probe_key,
                  error_ceiling_key, ceiling_hits_key, ceiling_confidence_key)
        invalidate_cache!
      end

      # Snapshot for dashboard / debugging.
      def state
        vals = redis.pipelined do |p|
          p.get(rate_key)
          p.get(cooldown_key)
          p.get(probe_key)
          p.get(error_ceiling_key)
          p.get(ceiling_hits_key)
          p.get(ceiling_confidence_key)
        end
        build_state_snapshot(vals)
      end

      def rate_key                = "#{REDIS_PREFIX}:#{@name}:current_rate"
      def cooldown_key            = "#{REDIS_PREFIX}:#{@name}:last_decrease"
      def probe_key               = "#{REDIS_PREFIX}:#{@name}:last_probe"
      def error_ceiling_key       = "#{REDIS_PREFIX}:#{@name}:error_ceiling"
      def ceiling_hits_key        = "#{REDIS_PREFIX}:#{@name}:ceiling_hits"
      def ceiling_confidence_key  = "#{REDIS_PREFIX}:#{@name}:ceiling_confidence"

      # ── Lua scripts ──────────────────────────────────────────────

      LUA_SCRIPTS = {
        # Atomically: initialise rate if missing, check cooldown + probe window,
        # check sliding-window utilization, compute dynamic ceiling threshold
        # from hits + confidence, then increase if utilization is sufficient.
        #
        # KEYS: rate_key, cooldown_key, probe_key, sliding_window_key,
        #       error_ceiling_key, ceiling_hits_key, ceiling_confidence_key
        # ARGV: cooldown_dur, probe_win, inc_by, max_rate, init_rate, now,
        #       sw_interval, util_threshold, ceiling_threshold,
        #       hit_penalty, confidence_penalty
        success: <<~LUA,
          local rate_key, cooldown_key, probe_key = KEYS[1], KEYS[2], KEYS[3]
          local sw_key            = KEYS[4]
          local ceiling_key       = KEYS[5]
          local hits_key          = KEYS[6]
          local confidence_key    = KEYS[7]

          local cooldown_dur     = tonumber(ARGV[1])
          local probe_win        = tonumber(ARGV[2])
          local inc_by           = tonumber(ARGV[3])
          local max_rate         = tonumber(ARGV[4])
          local init_rate        = tonumber(ARGV[5])
          local now              = tonumber(ARGV[6])
          local sw_interval      = tonumber(ARGV[7])
          local util_threshold   = tonumber(ARGV[8])
          local ceil_threshold   = tonumber(ARGV[9])
          local hit_pen          = tonumber(ARGV[10])
          local conf_pen         = tonumber(ARGV[11])

          -- Initialise on first call
          local current = tonumber(redis.call("GET", rate_key))
          if not current then
            redis.call("SET", rate_key, init_rate)
            redis.call("SET", probe_key, tostring(now))
            return 0
          end

          -- Respect cooldown after a decrease
          local last_dec = redis.call("GET", cooldown_key)
          if last_dec and (now - tonumber(last_dec)) < cooldown_dur then return 0 end

          -- Respect probe window
          local last_prb = redis.call("GET", probe_key)
          if last_prb and (now - tonumber(last_prb)) < probe_win then return 0 end

          -- ── Utilization gate ──
          local utilization = 1.0
          if sw_key and sw_key ~= "" and sw_interval > 0 and current > 0 then
            redis.call("ZREMRANGEBYSCORE", sw_key, 0, now - sw_interval)
            local sw_count = redis.call("ZCARD", sw_key)
            utilization = sw_count / current
          end
          if utilization < util_threshold then return 0 end

          -- ── Dynamic error ceiling gate ──
          local ceiling = tonumber(redis.call("GET", ceiling_key))
          if ceiling and ceiling > 0 and (current + inc_by) >= ceiling then
            local hits       = tonumber(redis.call("GET", hits_key)) or 0
            local confidence = tonumber(redis.call("GET", confidence_key)) or 0
            local dynamic    = ceil_threshold + (hits * hit_pen) + (confidence * conf_pen)
            if dynamic > 1.0 then dynamic = 1.0 end
            if utilization < dynamic then return 0 end
          end

          local new_rate = current + inc_by
          if max_rate > 0 then new_rate = math.min(new_rate, max_rate) end
          redis.call("SET", rate_key, new_rate)
          redis.call("SET", probe_key, tostring(now))
          return new_rate
        LUA

        # Atomically: read current rate (or use initial), apply decrease_factor,
        # floor at min_rate, set cooldown timestamp, record error ceiling.
        # If the new ceiling is within 20% of the old one, increment the hit
        # counter. Otherwise reset it to 1 and clear confidence (new ceiling zone).
        #
        # KEYS: rate_key, cooldown_key, error_ceiling_key, ceiling_hits_key
        decrease: <<~LUA
          local rate_key, cooldown_key = KEYS[1], KEYS[2]
          local ceiling_key = KEYS[3]
          local hits_key    = KEYS[4]
          local dec_factor = tonumber(ARGV[1])
          local min_rate   = tonumber(ARGV[2])
          local init_rate  = tonumber(ARGV[3])
          local now        = tonumber(ARGV[4])

          local current = tonumber(redis.call("GET", rate_key)) or init_rate

          -- Track ceiling hits: same zone (±20%) → increment, new zone → reset
          local old_ceiling = tonumber(redis.call("GET", ceiling_key))
          if old_ceiling and old_ceiling > 0 and math.abs(current - old_ceiling) <= (old_ceiling * 0.2) then
            redis.call("INCR", hits_key)
          else
            redis.call("SET", hits_key, 1)
          end
          redis.call("SET", ceiling_key, current)

          local new_rate = math.max(math.ceil(current * dec_factor), min_rate)
          redis.call("SET", rate_key, new_rate)
          redis.call("SET", cooldown_key, tostring(now))
          return new_rate
        LUA
      }.freeze

      private

      def success_keys
        [rate_key, cooldown_key, probe_key,
         @sliding_window_key.to_s, error_ceiling_key,
         ceiling_hits_key, ceiling_confidence_key]
      end

      def success_argv
        [
          @config[:cooldown_after_decrease],
          @config[:probe_window],
          @config[:increase_by],
          @config[:max_rate] || 0,
          @config[:initial_rate],
          Time.now.to_f,
          @window_interval || 0,
          @config[:utilization_threshold] || 0.7,
          @config[:ceiling_threshold] || 0.9,
          HIT_PENALTY,
          CONFIDENCE_PENALTY
        ]
      end

      def build_state_snapshot(vals)
        rate_val, decrease_val, probe_val, ceiling_val, hits_val, conf_val = vals
        {
          current_rate: rate_val ? rate_val.to_i : @config[:initial_rate],
          last_decrease_at: decrease_val&.to_f,
          last_probe_at: probe_val&.to_f,
          error_ceiling: ceiling_val&.to_i,
          ceiling_hits: hits_val.to_i,
          ceiling_confidence: conf_val.to_i,
          cooldown_active: cooldown_active?
        }
      end

      def cooldown_active?
        last_decrease = redis.get(cooldown_key)
        return false unless last_decrease

        Time.now.to_f - last_decrease.to_f < @config[:cooldown_after_decrease]
      end

      def invalidate_cache!
        @cached_rate = nil
        @cached_at = 0.0
      end

      # Executes a named Lua script via EVALSHA, reloading on NOSCRIPT.
      def execute_lua(script_name, keys:, argv:)
        sha = lua_shas[script_name] ||= redis.script(:load, LUA_SCRIPTS[script_name])
        redis.evalsha(sha, keys: keys, argv: argv)
      rescue Redis::CommandError => e
        raise unless e.message.include?("NOSCRIPT")

        sha = lua_shas[script_name] = redis.script(:load, LUA_SCRIPTS[script_name])
        redis.evalsha(sha, keys: keys, argv: argv)
      end

      def lua_shas
        @lua_shas ||= {}
      end

      def redis
        @redis ||= Redis.new(url: Hanikamu::RateLimit.config.redis_url)
      end
    end
  end
end
