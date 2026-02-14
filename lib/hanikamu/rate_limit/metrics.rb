# frozen_string_literal: true

module Hanikamu
  module RateLimit
    module Metrics
      LIMITS_SET_KEY = "hanikamu:rate_limit:metrics:limits"
      LIMITS_SET_TTL = 604_800 # 7 days
      LIMIT_META_PREFIX = "hanikamu:rate_limit:metrics:limit:meta:"
      LIMIT_COUNTS_PREFIX = "hanikamu:rate_limit:metrics:limit:counts:"
      LIMIT_REALTIME_COUNTS_PREFIX = "hanikamu:rate_limit:metrics:limit:realtime:"
      OVERRIDE_META_PREFIX = "hanikamu:rate_limit:metrics:override:meta:"
      OVERRIDE_META_TTL = 86_400 # 1 day
      OVERRIDE_HISTORY_PREFIX = "hanikamu:rate_limit:metrics:override:history:"
      OVERRIDE_REALTIME_HISTORY_PREFIX = "hanikamu:rate_limit:metrics:override:realtime:"
      LIMIT_LIFETIME_PREFIX = "hanikamu:rate_limit:metrics:limit:lifetime:"
      DASHBOARD_CACHE_TTL = 1 # seconds
      REDIS_INFO_CACHE_TTL = 10 # seconds

      @dashboard_cache = nil
      @dashboard_cache_at = 0
      @dashboard_mutex = Mutex.new
      @redis_info_cache = nil
      @redis_info_cache_at = 0
      @redis_info_mutex = Mutex.new

      module_function

      # ── Recording ──────────────────────────────────────────────

      def record_limit(limit_key, meta)
        sanitized = meta.compact.transform_values(&:to_s)
        return nil if sanitized.empty?

        redis.pipelined do |p|
          p.sadd(LIMITS_SET_KEY, limit_key)
          p.expire(LIMITS_SET_KEY, LIMITS_SET_TTL)
          p.hset(limit_meta_key(limit_key), sanitized)
          p.expire(limit_meta_key(limit_key), ttl_window_seconds)
        end
      rescue Redis::BaseError
        nil
      end

      def record_allowed(limit_key)
        increment_count(limit_key, "allowed")
      end

      def record_blocked(limit_key)
        increment_count(limit_key, "blocked")
      end

      def record_override(registry, remaining, reset)
        return nil if registry.nil? || registry.to_s.empty?

        write_override(registry, remaining, reset, Time.now.to_i)
      rescue Redis::BaseError
        nil
      end

      def record_registry_meta(limit_key, key_prefix, rate, interval, klass_name, method_name)
        record_limit(limit_key, {
                       "key_prefix" => key_prefix, "rate" => rate, "interval" => interval,
                       "klass_name" => klass_name, "method" => method_name,
                       "registry" => registry_from_key_prefix(key_prefix)
                     })
      end

      # ── Snapshots ──────────────────────────────────────────────

      def limits_snapshot
        limit_keys = redis.smembers(LIMITS_SET_KEY)
        recorded_entries = build_recorded_entries(limit_keys)
        registry_entries = build_registry_entries
        all_entries = deduplicate_entries(recorded_entries, registry_entries)
        pipeline_build_snapshots(all_entries)
      rescue Redis::BaseError
        []
      end

      def dashboard_payload
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cached = @dashboard_mutex.synchronize do
          @dashboard_cache if @dashboard_cache && (now - @dashboard_cache_at) < DASHBOARD_CACHE_TTL
        end
        return cached if cached

        payload = build_dashboard_payload
        @dashboard_mutex.synchronize do
          @dashboard_cache = payload
          @dashboard_cache_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        payload
      end

      def build_dashboard_payload
        {
          "generated_at" => Time.now.to_i,
          "bucket_seconds" => cfg_bucket_seconds,
          "window_seconds" => cfg_window_seconds,
          "metrics_realtime_bucket_seconds" => cfg_realtime_bucket_seconds,
          "metrics_realtime_window_seconds" => cfg_realtime_window_seconds,
          "redis" => cached_redis_info,
          "limits" => limits_snapshot.sort_by { |l| l.fetch("key_prefix", "") }
        }
      end

      def cached_redis_info
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cached = @redis_info_mutex.synchronize do
          @redis_info_cache if @redis_info_cache && (now - @redis_info_cache_at) < REDIS_INFO_CACHE_TTL
        end
        return cached if cached

        info = redis_info
        @redis_info_mutex.synchronize do
          @redis_info_cache = info
          @redis_info_cache_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        info
      end

      def redis_info
        info = redis.info
        {
          "version" => info["redis_version"],
          "uptime" => info["uptime_in_seconds"].to_i,
          "connected_clients" => info["connected_clients"].to_i,
          "used_memory_human" => info["used_memory_human"],
          "used_memory_peak_human" => info["used_memory_peak_human"],
          "total_commands_processed" => info["total_commands_processed"].to_i,
          "keyspace_hits" => info["keyspace_hits"].to_i,
          "keyspace_misses" => info["keyspace_misses"].to_i
        }
      rescue Redis::BaseError
        nil
      end

      def limit_snapshot(limit_key)
        meta = redis.hgetall(limit_meta_key(limit_key))
        return nil if meta.empty?

        build_snapshot(limit_key,
                       rate: meta.fetch("rate").to_i, interval: meta.fetch("interval").to_f,
                       klass_name: meta["klass_name"], method_name: meta["method"],
                       registry: meta["registry"], key_prefix: meta.fetch("key_prefix"))
      rescue KeyError, Redis::BaseError
        nil
      end

      def registry_limits_snapshot
        Hanikamu::RateLimit.registry.keys.filter_map do |reg_key|
          cfg = Hanikamu::RateLimit.fetch_limit(reg_key)
          key_prefix = cfg.fetch(:key_prefix)
          rate = cfg.fetch(:rate).to_i
          interval = cfg.fetch(:interval).to_f
          build_snapshot(build_limit_key(key_prefix, rate, interval),
                         rate: rate, interval: interval, registry: reg_key, key_prefix: key_prefix)
        rescue Dry::Container::Error, KeyError, Redis::BaseError
          nil
        end
      end

      def override_snapshot(registry)
        return nil if registry.nil? || registry.to_s.empty?

        live_override(registry) || stored_override(registry)
      end

      # ── Private helpers ────────────────────────────────────────

      # Pipeline 1: fetch all limit metas in one round-trip
      def pipeline_metas(limit_keys)
        return [] if limit_keys.empty?

        redis.pipelined do |p|
          limit_keys.each { |lk| p.hgetall(limit_meta_key(lk)) }
        end
      end

      def build_recorded_entries(limit_keys)
        pipeline_metas(limit_keys).each_with_index.filter_map do |meta, idx|
          next if meta.empty?

          entry_from_meta(limit_keys[idx], meta)
        rescue KeyError
          nil
        end
      end

      def entry_from_meta(limit_key, meta)
        { limit_key: limit_key, rate: meta.fetch("rate").to_i, interval: meta.fetch("interval").to_f,
          klass_name: meta["klass_name"], method_name: meta["method"],
          registry: meta["registry"], key_prefix: meta.fetch("key_prefix") }
      end

      def build_registry_entries
        Hanikamu::RateLimit.registry.keys.filter_map do |reg_key|
          cfg = Hanikamu::RateLimit.fetch_limit(reg_key)
          key_prefix = cfg.fetch(:key_prefix)
          rate = cfg.fetch(:rate).to_i
          interval = cfg.fetch(:interval).to_f
          { limit_key: build_limit_key(key_prefix, rate, interval),
            rate: rate, interval: interval, registry: reg_key, key_prefix: key_prefix }
        rescue Dry::Container::Error, KeyError
          nil
        end
      end

      # Deduplicate recorded + registry entries (recorded wins on same key_prefix)
      def deduplicate_entries(recorded, registry)
        merged = {}
        recorded.each { |e| merged[e[:key_prefix]] = e }
        registry.each { |e| merged[e[:key_prefix]] ||= e }
        merged.values
      end

      # Pipeline 2: fetch all per-limit data in one round-trip and assemble snapshots
      def pipeline_build_snapshots(entries)
        return [] if entries.empty?

        registries = entries.map { |e| e[:registry]&.to_s }
        override_keys = resolve_override_keys(registries)
        results = pipeline_all_reads(entries, override_keys, registries)
        assemble_snapshots(entries, override_keys, results)
      end

      def resolve_override_keys(registries)
        registries.map do |reg|
          reg && !reg.empty? ? Hanikamu::RateLimit.override_key_for(reg) : nil
        end
      end

      def pipeline_all_reads(entries, override_keys, registries)
        redis.pipelined do |p|
          entries.each_with_index do |e, i|
            pipeline_base_reads(p, e)
            pipeline_override_reads(p, override_keys[i], registries[i]) if override_keys[i]
          end
        end
      end

      def pipeline_base_reads(pipe, entry)
        pipe.zcard(entry[:limit_key])
        pipe.hgetall(limit_lifetime_key(entry[:limit_key]))
        pipe.hgetall(limit_counts_key(entry[:limit_key]))
        pipe.hgetall(limit_realtime_counts_key(entry[:limit_key]))
      end

      def pipeline_override_reads(pipe, override_key, registry)
        pipe.get(override_key)
        pipe.ttl(override_key)
        pipe.hgetall(override_meta_key(registry))
        pipe.hgetall(override_history_key(registry))
        pipe.hgetall(override_realtime_history_key(registry))
      end

      def assemble_snapshots(entries, override_keys, results)
        snapshots = []
        offset = 0

        entries.each_with_index do |entry, i|
          base_data = results[offset, 4]
          offset += 4

          override_hash, offset = extract_override(override_keys[i], results, offset)

          snapshots << assemble_single_snapshot(entry, base_data, override_hash)
        end

        snapshots
      end

      def extract_override(override_key, results, offset)
        if override_key
          override_data = results[offset, 5]
          offset += 5
          [build_override_from_pipeline(*override_data), offset]
        else
          [{ "override" => nil, "override_history" => nil, "override_realtime_history" => nil }, offset]
        end
      end

      def assemble_single_snapshot(entry, base_data, override_hash)
        current_count = base_data[0].to_i
        entry_base_hash(entry, current_count)
          .merge(snapshot_aggregates(base_data))
          .merge(override_hash)
      end

      def entry_base_hash(entry, current_count)
        { "limit_key" => entry[:limit_key], "rate" => entry[:rate], "interval" => entry[:interval],
          "klass_name" => entry[:klass_name], "method" => entry[:method_name],
          "registry" => entry[:registry]&.to_s, "key_prefix" => entry[:key_prefix],
          "current_count" => current_count,
          "current_remaining" => [entry[:rate] - current_count, 0].max }
      end

      def snapshot_aggregates(base_data)
        { "lifetime" => parse_lifetime(base_data[1]),
          "history" => parse_history(base_data[2], cfg_window_seconds, cfg_bucket_seconds),
          "realtime_history" => parse_history(base_data[3], cfg_realtime_window_seconds,
                                              cfg_realtime_bucket_seconds) }
      end

      def parse_lifetime(data)
        { "allowed" => data.fetch("allowed", "0").to_i,
          "blocked" => data.fetch("blocked", "0").to_i }
      end

      def parse_history(counts, window, bucket_seconds)
        buckets = buckets_for_window(window, bucket_seconds)
        {
          "buckets" => buckets,
          "allowed" => buckets.map { |b| counts.fetch("allowed:#{b}", "0").to_i },
          "blocked" => buckets.map { |b| counts.fetch("blocked:#{b}", "0").to_i }
        }
      end

      def build_override_from_pipeline(live_remaining, live_ttl, stored_meta,
                                       override_hist, override_rt_hist)
        override = resolve_override(live_remaining, live_ttl, stored_meta)
        {
          "override" => override,
          "override_history" => parse_override_history(override_hist, cfg_window_seconds,
                                                       cfg_bucket_seconds),
          "override_realtime_history" => parse_override_history(override_rt_hist,
                                                                cfg_realtime_window_seconds,
                                                                cfg_realtime_bucket_seconds)
        }
      end

      def resolve_override(live_remaining, live_ttl, stored_meta)
        # Try live override first
        if live_remaining && live_ttl&.positive?
          remaining = Integer(live_remaining, exception: false)
          if remaining
            return { "remaining" => remaining, "reset" => live_ttl,
                     "updated_at" => Time.now.to_i }
          end
        end
        # Fall back to stored meta
        return nil if stored_meta.nil? || stored_meta.empty?

        remaining_reset = compute_remaining_reset(stored_meta)
        return nil unless remaining_reset

        { "remaining" => stored_meta["remaining"].to_i, "reset" => remaining_reset,
          "updated_at" => stored_meta["updated_at"].to_i }
      end

      def parse_override_history(raw, window, bucket_seconds)
        return nil if raw.nil? || raw.empty?

        buckets = buckets_for_window(window, bucket_seconds)
        {
          "buckets" => buckets,
          "remaining" => buckets.map { |b| raw.fetch("remaining:#{b}", nil)&.to_i },
          "reset" => buckets.map { |b| raw.fetch("reset:#{b}", nil)&.to_i }
        }
      end

      def build_snapshot(limit_key, rate:, interval:, key_prefix:,
                         registry: nil, klass_name: nil, method_name: nil)
        current_count = redis.zcard(limit_key).to_i
        registry_str = registry&.to_s
        base_snapshot(limit_key, rate, interval, key_prefix,
                      klass_name, method_name, registry_str, current_count)
          .merge(override_snapshots(registry_str))
      end

      def base_snapshot(limit_key, rate, interval, key_prefix,
                        klass_name, method_name, registry, current_count)
        {
          "limit_key" => limit_key, "rate" => rate, "interval" => interval,
          "klass_name" => klass_name, "method" => method_name,
          "registry" => registry, "key_prefix" => key_prefix,
          "current_count" => current_count,
          "current_remaining" => [rate - current_count, 0].max,
          "lifetime" => lifetime_snapshot(limit_key),
          "history" => history_snapshot(limit_key),
          "realtime_history" => realtime_history_snapshot(limit_key)
        }
      end

      def override_snapshots(registry)
        unless registry
          return { "override" => nil, "override_history" => nil,
                   "override_realtime_history" => nil }
        end

        { "override" => override_snapshot(registry),
          "override_history" => override_history_snapshot(registry),
          "override_realtime_history" => override_history_snapshot(registry, realtime: true) }
      end

      def live_override(registry)
        override_key = Hanikamu::RateLimit.override_key_for(registry)
        remaining_value, ttl = redis.pipelined do |p|
          p.get(override_key)
          p.ttl(override_key)
        end
        return nil unless remaining_value && ttl&.positive?

        remaining = Integer(remaining_value, exception: false)
        return nil if remaining.nil?

        { "remaining" => remaining, "reset" => ttl, "updated_at" => Time.now.to_i }
      end

      def stored_override(registry)
        meta = redis.hgetall(override_meta_key(registry))
        return nil if meta.empty?

        remaining_reset = compute_remaining_reset(meta)
        return nil unless remaining_reset

        { "remaining" => meta["remaining"].to_i, "reset" => remaining_reset,
          "updated_at" => meta["updated_at"].to_i }
      end

      def compute_remaining_reset(meta)
        reset = meta["reset"]&.to_i
        updated_at = meta["updated_at"]&.to_i
        return nil if reset.nil? || updated_at.nil?

        remaining = reset - (Time.now.to_i - updated_at)
        remaining.positive? ? remaining : nil
      end

      def write_override(registry, remaining, reset, now)
        bucket = bucket_for(now, cfg_bucket_seconds)
        rt_bucket = bucket_for(now, cfg_realtime_bucket_seconds)
        redis.pipelined do |p|
          write_override_meta(p, registry, remaining, reset, now)
          write_override_history(p, registry, remaining, reset, bucket)
          write_override_realtime(p, registry, remaining, reset, rt_bucket)
        end
      end

      def write_override_meta(pipe, registry, remaining, reset, now)
        key = override_meta_key(registry)
        pipe.hset(key, { "remaining" => remaining, "reset" => reset, "updated_at" => now })
        pipe.expire(key, OVERRIDE_META_TTL)
      end

      def write_override_history(pipe, registry, remaining, reset, bucket)
        key = override_history_key(registry)
        pipe.hset(key, override_bucket_data(remaining, reset, bucket))
        pipe.expire(key, ttl_window_seconds)
      end

      def write_override_realtime(pipe, registry, remaining, reset, bucket)
        key = override_realtime_history_key(registry)
        pipe.hset(key, override_bucket_data(remaining, reset, bucket))
        pipe.expire(key, ttl_window_seconds(cfg_realtime_window_seconds, cfg_realtime_bucket_seconds))
      end

      def override_bucket_data(remaining, reset, bucket)
        { "remaining:#{bucket}" => remaining, "reset:#{bucket}" => reset }
      end

      def override_history_snapshot(registry, realtime: false)
        return nil if registry.nil? || registry.to_s.empty?

        window, bucket_seconds, raw = override_history_data(registry, realtime)
        buckets = buckets_for_window(window, bucket_seconds)
        {
          "buckets" => buckets,
          "remaining" => buckets.map { |b| raw.fetch("remaining:#{b}", nil)&.to_i },
          "reset" => buckets.map { |b| raw.fetch("reset:#{b}", nil)&.to_i }
        }
      rescue Redis::BaseError
        nil
      end

      def override_history_data(registry, realtime)
        if realtime
          [cfg_realtime_window_seconds, cfg_realtime_bucket_seconds,
           redis.hgetall(override_realtime_history_key(registry))]
        else
          [cfg_window_seconds, cfg_bucket_seconds,
           redis.hgetall(override_history_key(registry))]
        end
      end

      def history_snapshot(limit_key)
        history_snapshot_for(limit_counts_key(limit_key), cfg_window_seconds, cfg_bucket_seconds)
      end

      def realtime_history_snapshot(limit_key)
        history_snapshot_for(limit_realtime_counts_key(limit_key),
                             cfg_realtime_window_seconds, cfg_realtime_bucket_seconds)
      end

      def lifetime_snapshot(limit_key)
        data = redis.hgetall(limit_lifetime_key(limit_key))
        { "allowed" => data.fetch("allowed", "0").to_i,
          "blocked" => data.fetch("blocked", "0").to_i }
      rescue Redis::BaseError
        { "allowed" => 0, "blocked" => 0 }
      end

      def history_snapshot_for(counts_key, window, bucket_seconds)
        counts = redis.hgetall(counts_key)
        buckets = buckets_for_window(window, bucket_seconds)
        {
          "buckets" => buckets,
          "allowed" => buckets.map { |b| counts.fetch("allowed:#{b}", "0").to_i },
          "blocked" => buckets.map { |b| counts.fetch("blocked:#{b}", "0").to_i }
        }
      end

      def increment_count(limit_key, label)
        now = Time.now.to_i
        redis.pipelined do |p|
          increment_bucketed_count(p, limit_counts_key(limit_key), label, now,
                                   cfg_bucket_seconds, ttl_window_seconds)
          increment_bucketed_count(p, limit_realtime_counts_key(limit_key), label, now,
                                   cfg_realtime_bucket_seconds,
                                   ttl_window_seconds(cfg_realtime_window_seconds, cfg_realtime_bucket_seconds))
          p.hincrby(limit_lifetime_key(limit_key), label, 1)
        end
      rescue Redis::BaseError
        nil
      end

      def increment_bucketed_count(pipe, key, label, now, bucket_seconds, ttl)
        bucket = bucket_for(now, bucket_seconds)
        pipe.hincrby(key, "#{label}:#{bucket}", 1)
        pipe.expire(key, ttl)
      end

      def registry_from_key_prefix(key_prefix)
        match = key_prefix.match(/:registry:([^:]+)$/)
        match ? match[1] : nil
      end

      # ── Config accessors ───────────────────────────────────────

      def cfg_bucket_seconds     = Hanikamu::RateLimit.config.metrics_bucket_seconds
      def cfg_window_seconds     = Hanikamu::RateLimit.config.metrics_window_seconds
      def cfg_realtime_bucket_seconds = Hanikamu::RateLimit.config.metrics_realtime_bucket_seconds
      def cfg_realtime_window_seconds = Hanikamu::RateLimit.config.metrics_realtime_window_seconds

      # ── Key builders / utilities ───────────────────────────────

      def bucket_for(timestamp, bucket_seconds)
        timestamp - (timestamp % bucket_seconds)
      end

      def merge_limits(recorded, registry_limits)
        merged = {}
        recorded.each { |l| merged[l["key_prefix"] || l["limit_key"]] = l }
        registry_limits.each { |l| merged[l["key_prefix"] || l["limit_key"]] ||= l }
        merged.values
      end

      def buckets_for_window(window = cfg_window_seconds, bucket_seconds = cfg_bucket_seconds)
        now = Time.now.to_i
        start = now - window
        buckets = []
        bucket = bucket_for(start, bucket_seconds)
        while bucket <= now
          buckets << bucket
          bucket += bucket_seconds
        end
        buckets
      end

      def ttl_window_seconds(window = cfg_window_seconds, bucket_seconds = cfg_bucket_seconds)
        window + bucket_seconds
      end

      def build_limit_key(key_prefix, rate, interval)
        "#{key_prefix}:#{rate}:#{interval}"
      end

      def limit_meta_key(limit_key)        = "#{LIMIT_META_PREFIX}#{limit_key}"
      def limit_counts_key(limit_key)      = "#{LIMIT_COUNTS_PREFIX}#{limit_key}"
      def limit_realtime_counts_key(limit_key) = "#{LIMIT_REALTIME_COUNTS_PREFIX}#{limit_key}"
      def limit_lifetime_key(limit_key)    = "#{LIMIT_LIFETIME_PREFIX}#{limit_key}"
      def override_meta_key(registry)      = "#{OVERRIDE_META_PREFIX}#{registry}"
      def override_history_key(registry)   = "#{OVERRIDE_HISTORY_PREFIX}#{registry}"
      def override_realtime_history_key(registry) = "#{OVERRIDE_REALTIME_HISTORY_PREFIX}#{registry}"

      def redis
        Hanikamu::RateLimit.send(:redis_client)
      end
    end
  end
end
