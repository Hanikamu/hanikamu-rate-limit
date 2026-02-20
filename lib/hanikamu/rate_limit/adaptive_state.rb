# frozen_string_literal: true

require "redis"

module Hanikamu
  module RateLimit
    # Manages adaptive rate-limiting state using a ceiling-based linear
    # probing algorithm.
    #
    # State is persisted in Redis so it survives restarts and is shared
    # across processes.  All mutations use Lua scripts for atomicity.
    #
    # How it works:
    #   1. Start at the configured baseline `rate`.
    #   2. After N consecutive successful calls (N = current rate), probe +1.
    #   3. Keep probing until `max_rate` or a rate-limit event occurs.
    #   4. When a captured event is classified as "rate_limit" (manually or
    #      via auto-inherit), the `adaptive_rate` stored on that event
    #      becomes the new ceiling and the current rate drops below it.
    #   5. The ceiling is a hard cap — the rate never probes above it.
    #   6. Running at / near the ceiling without 429s builds trust:
    #      each success cycle increments ceiling_hits.  More hits =
    #      shorter probe cooldown = probe sooner.
    #   7. A 429 resets ceiling_hits to 0 (trust lost).
    #   8. When ceiling_hits grows large enough, the probe cooldown
    #      shrinks to zero and the ceiling is cleared, resuming normal
    #      probing.
    #   9. Never go below `min_rate`.
    #
    # Ceiling confidence scoring:
    #   The Learning UI syncs a "confidence" score into Redis: the number
    #   of distinct 1-minute encounter windows that contain at least one
    #   rate_limit-classified event (not raw event count, to avoid
    #   inflation from concurrent bursts).
    #
    #   Probe cooldown formula:
    #     raw      = base_cooldown × (1 + confidence)
    #     erosion  = raw / (1 + ceiling_hits)
    #     effective = clamp(erosion, 0, max_cooldown)
    #
    #   More successful ceiling hits = shorter cooldown = probe sooner.
    #   More classified rate-limit encounters = longer cooldown = probe later.
    #
    #   Dynamic ceiling threshold (utilization needed to break through):
    #     effective = base_ceiling_threshold + (confidence × CONFIDENCE_PENALTY)
    #
    #   ceiling_hits no longer penalise the threshold — they only shorten
    #   the cooldown.
    class AdaptiveState
      REDIS_PREFIX = "hanikamu:rate_limit:adaptive"

      # Local cache avoids a Redis GET on every rate-limited call.
      RATE_CACHE_TTL = 1.0

      # Per-classified-event caution penalty added to the ceiling threshold.
      CONFIDENCE_PENALTY = 0.05

      # Base seconds between probe attempts near the error ceiling.
      # Effective cooldown = BASE_PROBE_COOLDOWN * (1 + confidence) / (1 + ceiling_hits),
      # capped at MAX_PROBE_COOLDOWN.
      BASE_PROBE_COOLDOWN = 30

      # Hard cap on the effective probe cooldown (seconds).
      # Configurable per-limit via `max_probe_cooldown:`.
      MAX_PROBE_COOLDOWN = 300

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
      # Atomically increments the consecutive success counter and probes +1
      # when enough successes have accumulated at the current rate.
      # Returns the new rate (> 0) on increase, 0 when skipped.
      def record_success!
        result = execute_lua(:success,
                             keys: success_keys,
                             argv: success_argv)
        invalidate_cache! if result.to_i.positive?
        result.to_i
      end

      # Called when a captured event is classified as "rate_limit".
      # Sets the current rate to the given ceiling and resets the success
      # counter.
      #
      # ceiling_hits are NOT reset — they track successful utilization
      # cycles at the ceiling, not 429 encounters.  Hits only reset when
      # the ceiling value moves to a completely different zone (>20%
      # change), because that means a new ceiling level.
      #
      # Idempotent: if the current rate is already at or below the
      # requested ceiling, the rate is not changed.  The ceiling value
      # is still recorded.
      #
      # Returns the new rate, or nil if the drop was skipped.
      def drop_to_rate!(ceiling)
        new_rate = ceiling.to_i.clamp(@config[:min_rate], @config[:max_rate] || Float::INFINITY)
        current = redis.get(rate_key)&.to_i || @config[:initial_rate]

        if current <= new_rate
          # Rate already at or below the target — don't change it,
          # but record the ceiling (hits stay as-is).
          update_ceiling_value(new_rate)
          return nil
        end

        redis.multi do |txn|
          txn.set(rate_key, new_rate)
          txn.set(success_count_key, 0)
        end
        update_ceiling_value(new_rate)
        invalidate_cache!
        new_rate
      end

      # Syncs the ceiling confidence from the database.
      # Called by the Learning UI after classification changes.
      # `count` is the number of rate_limit-classified events for this registry.
      def sync_ceiling_confidence!(count)
        redis.set(ceiling_confidence_key, [count.to_i, 0].max)
      end

      # Clears all persisted adaptive state; rate reverts to initial_rate.
      def reset!
        redis.del(rate_key, success_count_key,
                  error_ceiling_key, ceiling_hits_key, ceiling_confidence_key,
                  last_probe_at_key)
        invalidate_cache!
      end

      # Snapshot for dashboard / debugging.
      def state
        vals = redis.pipelined do |p|
          p.get(rate_key)
          p.get(success_count_key)
          p.get(error_ceiling_key)
          p.get(ceiling_hits_key)
          p.get(ceiling_confidence_key)
          p.get(last_probe_at_key)
        end
        build_state_snapshot(vals)
      end

      def rate_key                = "#{REDIS_PREFIX}:#{@name}:current_rate"
      def success_count_key       = "#{REDIS_PREFIX}:#{@name}:success_count"
      def error_ceiling_key       = "#{REDIS_PREFIX}:#{@name}:error_ceiling"
      def ceiling_hits_key        = "#{REDIS_PREFIX}:#{@name}:ceiling_hits"
      def ceiling_confidence_key  = "#{REDIS_PREFIX}:#{@name}:ceiling_confidence"
      def last_probe_at_key       = "#{REDIS_PREFIX}:#{@name}:last_probe_at"

      # ── Lua scripts ──────────────────────────────────────────────

      LUA_SCRIPTS = {
        # Atomically: initialise rate if missing, increment success counter,
        # check if enough successes have accumulated (N = current rate),
        # check sliding-window utilization, build trust via ceiling_hits on
        # sustained success, then increase by +1 if eligible.
        #
        # KEYS: rate_key, success_count_key, sliding_window_key,
        #       error_ceiling_key, ceiling_hits_key, ceiling_confidence_key,
        #       last_probe_at_key
        # ARGV: max_rate, init_rate, now, sw_interval, util_threshold,
        #       ceiling_threshold, confidence_penalty, min_rate,
        #       base_probe_cooldown, max_probe_cooldown
        success: <<~LUA
          local rate_key         = KEYS[1]
          local success_key      = KEYS[2]
          local sw_key           = KEYS[3]
          local ceiling_key      = KEYS[4]
          local hits_key         = KEYS[5]
          local confidence_key   = KEYS[6]
          local probe_at_key     = KEYS[7]

          local max_rate         = tonumber(ARGV[1])
          local init_rate        = tonumber(ARGV[2])
          local now              = tonumber(ARGV[3])
          local sw_interval      = tonumber(ARGV[4])
          local util_threshold   = tonumber(ARGV[5])
          local ceil_threshold   = tonumber(ARGV[6])
          local conf_pen         = tonumber(ARGV[7])
          local min_rate         = tonumber(ARGV[8])
          local base_cooldown    = tonumber(ARGV[9])
          local max_cooldown     = tonumber(ARGV[10])

          -- Initialise on first call
          local current = tonumber(redis.call("GET", rate_key))
          if not current then
            redis.call("SET", rate_key, init_rate)
            redis.call("SET", success_key, 0)
            return 0
          end

          -- Already at max
          if max_rate > 0 and current >= max_rate then
            redis.call("SET", success_key, 0)
            return 0
          end

          -- Check sliding-window utilization: only probe when the window
          -- is at capacity (hits in the current interval >= current rate).
          if not sw_key or sw_key == "" or sw_interval <= 0 or current <= 0 then
            return 0
          end
          redis.call("ZREMRANGEBYSCORE", sw_key, 0, now - sw_interval)
          local sw_count = redis.call("ZCARD", sw_key)
          local utilization = sw_count / current
          if utilization < util_threshold then return 0 end

          -- Require N consecutive successes (tracked separately).
          local count = tonumber(redis.call("INCR", success_key))
          if count < current then return 0 end

          -- ── Build trust on sustained success near the ceiling ──
          -- Each success cycle (N successes at full utilization) at or
          -- near the ceiling increments ceiling_hits.  More hits = more
          -- trust = shorter probe cooldown.  ceiling_hits persist across
          -- 429s — they only reset when the ceiling moves to a different
          -- zone (>20 pct change).
          local ceiling = tonumber(redis.call("GET", ceiling_key))
          if ceiling and ceiling > 0 and current >= (ceiling - 1) then
            redis.call("INCR", hits_key)
          end

          -- ── Dynamic error ceiling gate ──
          if ceiling and ceiling > 0 and (current + 1) >= ceiling then
            local hits       = tonumber(redis.call("GET", hits_key)) or 0
            local confidence = tonumber(redis.call("GET", confidence_key)) or 0

            -- Probe cooldown: scales with confidence, eroded by trust.
            -- raw      = base × (1 + confidence)
            -- effective = raw / (1 + hits), capped at max_cooldown
            -- More hits = shorter wait; 429 resets hits → full cooldown.
            if base_cooldown and base_cooldown > 0 then
              local last_probe = tonumber(redis.call("GET", probe_at_key)) or 0
              local raw_cd     = base_cooldown * (1 + confidence)
              local cooldown   = raw_cd / (1 + hits)
              if max_cooldown and max_cooldown > 0 then
                cooldown = math.min(cooldown, max_cooldown)
              end
              if (now - last_probe) < cooldown then
                redis.call("SET", success_key, 0)
                return 0
              end
              redis.call("SET", probe_at_key, now)
            end

            -- Dynamic threshold gate (only confidence penalises)
            local dynamic = ceil_threshold + (confidence * conf_pen)
            if dynamic > 1.0 then dynamic = 1.0 end
            if utilization < dynamic then return 0 end
          end

          -- Probe +1
          local new_rate = current + 1
          if max_rate > 0 then new_rate = math.min(new_rate, max_rate) end
          new_rate = math.max(new_rate, min_rate)

          -- Ceiling hard cap — never probe above the ceiling.
          -- When the system earns a probe but the ceiling blocks it,
          -- erode confidence (a virtual successful probe).  Once
          -- confidence reaches 0, clear the ceiling and allow through.
          if ceiling and ceiling > 0 and new_rate > ceiling then
            local conf = tonumber(redis.call("GET", confidence_key)) or 0
            if conf > 0 then
              redis.call("DECR", confidence_key)
              redis.call("SET", success_key, 0)
              return 0
            end
            -- No confidence remaining — ceiling fully eroded.
            redis.call("DEL", ceiling_key)
            redis.call("DEL", hits_key)
            redis.call("DEL", confidence_key)
            redis.call("SET", rate_key, new_rate)
            redis.call("SET", success_key, 0)
            return new_rate
          end

          redis.call("SET", rate_key, new_rate)
          redis.call("SET", success_key, 0)
          return new_rate
        LUA
      }.freeze

      private

      def success_keys
        [rate_key, success_count_key,
         @sliding_window_key.to_s, error_ceiling_key,
         ceiling_hits_key, ceiling_confidence_key,
         last_probe_at_key]
      end

      def success_argv
        [
          @config[:max_rate] || 0,
          @config[:initial_rate],
          Time.now.to_f,
          @window_interval || 0,
          @config[:utilization_threshold] || 1.0,
          @config[:ceiling_threshold] || 0.9,
          CONFIDENCE_PENALTY,
          @config[:min_rate],
          @config[:probe_cooldown] || BASE_PROBE_COOLDOWN,
          @config[:max_probe_cooldown] || MAX_PROBE_COOLDOWN
        ]
      end

      # Two ceilings are in the same zone when they differ by ≤ 20%.
      def same_zone?(value, reference)
        (value - reference).abs <= (reference * 0.2)
      end

      # Updates the ceiling value and resets ceiling_hits if the ceiling
      # moved to a completely different zone (≤20% change).  If the
      # ceiling is in the same zone, hits are preserved — they represent
      # successful utilization cycles, not 429 encounters.
      def update_ceiling_value(new_ceiling)
        old_ceiling = redis.get(error_ceiling_key)&.to_i
        if old_ceiling&.positive? && same_zone?(new_ceiling, old_ceiling)
          # Same zone — keep existing ceiling_hits.
        else
          # New zone (or first ceiling) — reset hits counter.
          redis.set(ceiling_hits_key, 0)
        end
        redis.set(error_ceiling_key, new_ceiling)
      end

      def build_state_snapshot(vals)
        rate_val, count_val, ceiling_val, hits_val, conf_val, probe_at_val = vals
        snapshot = {
          current_rate: rate_val ? rate_val.to_i : @config[:initial_rate],
          consecutive_successes: count_val.to_i,
          error_ceiling: ceiling_val&.to_i,
          ceiling_hits: hits_val.to_i,
          ceiling_confidence: conf_val.to_i,
          last_probe_at: probe_at_val&.to_f
        }
        enrich_with_cooldown_info(snapshot)
        snapshot
      end

      # Computes the effective probe cooldown and remaining seconds until
      # the next probe attempt is allowed.  Only relevant when the rate is
      # near the error ceiling (current + 1 >= ceiling).
      def enrich_with_cooldown_info(snapshot) # rubocop:disable Metrics/AbcSize
        ceiling = snapshot[:error_ceiling]
        unless ceiling&.positive? && (snapshot[:current_rate] + 1) >= ceiling
          snapshot[:effective_cooldown] = nil
          snapshot[:cooldown_remaining] = nil
          return
        end

        base = @config[:probe_cooldown] || BASE_PROBE_COOLDOWN
        max  = @config[:max_probe_cooldown] || MAX_PROBE_COOLDOWN
        raw  = base * (1 + snapshot[:ceiling_confidence])
        effective = raw / (1 + snapshot[:ceiling_hits]).to_f
        effective = [effective, max].min if max.positive?

        snapshot[:effective_cooldown] = effective
        last = snapshot[:last_probe_at] || 0.0
        snapshot[:cooldown_remaining] = [effective - (Time.now.to_f - last), 0.0].max.round(1)
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
