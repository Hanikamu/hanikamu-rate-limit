# frozen_string_literal: true

RSpec.describe Hanikamu::RateLimit::Metrics do
  let(:redis_url) { ENV.fetch("REDIS_URL", "redis://localhost:6379/15") }
  let(:redis) { Redis.new(url: redis_url) }
  let(:limit_key) { "hanikamu:rate_limit:rate_queue:TestClass:call:5:60.0" }
  let(:key_prefix) { "hanikamu:rate_limit:rate_queue:registry:test_api" }
  let(:registry_limit_key) { "#{key_prefix}:10:30.0" }

  before do
    Hanikamu::RateLimit.configure do |config|
      config.redis_url = redis_url
      config.metrics_enabled = true
      config.metrics_bucket_seconds = 300
      config.metrics_window_seconds = 86_400
      config.metrics_realtime_bucket_seconds = 1
      config.metrics_realtime_window_seconds = 300
    end

    Hanikamu::RateLimit.reset_registry!

    # Clean metrics keys between tests
    scan_and_delete(redis, "hanikamu:rate_limit:metrics:*")
  end

  after do
    scan_and_delete(redis, "hanikamu:rate_limit:metrics:*")
    Hanikamu::RateLimit.reset_registry!
    Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }
  end

  describe ".record_limit" do
    it "stores limit metadata in Redis" do
      described_class.record_limit(limit_key, { "rate" => 5, "interval" => 60, "key_prefix" => "test" })

      expect(redis.sismember(described_class::LIMITS_SET_KEY, limit_key)).to be true
      meta = redis.hgetall("#{described_class::LIMIT_META_PREFIX}#{limit_key}")
      expect(meta).to include("rate" => "5", "interval" => "60", "key_prefix" => "test")
    end

    it "sets TTL on limits set key" do
      described_class.record_limit(limit_key, { "rate" => 5, "key_prefix" => "test" })

      ttl = redis.ttl(described_class::LIMITS_SET_KEY)
      expect(ttl).to be > 0
      expect(ttl).to be <= described_class::LIMITS_SET_TTL
    end

    it "records even when global metrics_enabled is false (caller gates)" do
      Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }
      described_class.record_limit(limit_key, { "rate" => 5, "key_prefix" => "test" })
      expect(redis.sismember(described_class::LIMITS_SET_KEY, limit_key)).to be true
    end

    it "returns nil when meta is empty after compaction" do
      result = described_class.record_limit(limit_key, { "rate" => nil, "interval" => nil })
      expect(result).to be_nil
    end

    it "strips nil values from metadata" do
      described_class.record_limit(limit_key, { "rate" => 5, "key_prefix" => "test", "extra" => nil })

      meta = redis.hgetall("#{described_class::LIMIT_META_PREFIX}#{limit_key}")
      expect(meta).not_to have_key("extra")
    end
  end

  describe ".record_allowed" do
    it "increments the allowed count in bucketed and lifetime keys" do
      described_class.record_allowed(limit_key)
      described_class.record_allowed(limit_key)

      lifetime = redis.hgetall("#{described_class::LIMIT_LIFETIME_PREFIX}#{limit_key}")
      expect(lifetime["allowed"].to_i).to eq(2)
    end

    it "increments bucketed counts" do
      described_class.record_allowed(limit_key)

      counts = redis.hgetall("#{described_class::LIMIT_COUNTS_PREFIX}#{limit_key}")
      total = counts.select { |k, _| k.start_with?("allowed:") }.values.sum(&:to_i)
      expect(total).to eq(1)
    end

    it "increments realtime counts" do
      described_class.record_allowed(limit_key)

      realtime = redis.hgetall("#{described_class::LIMIT_REALTIME_COUNTS_PREFIX}#{limit_key}")
      total = realtime.select { |k, _| k.start_with?("allowed:") }.values.sum(&:to_i)
      expect(total).to eq(1)
    end

    it "records even when global metrics_enabled is false (caller gates)" do
      Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }
      described_class.record_allowed(limit_key)
      lifetime = redis.hgetall("#{described_class::LIMIT_LIFETIME_PREFIX}#{limit_key}")
      expect(lifetime["allowed"].to_i).to eq(1)
    end
  end

  describe ".record_blocked" do
    it "increments the blocked count in lifetime key" do
      described_class.record_blocked(limit_key)

      lifetime = redis.hgetall("#{described_class::LIMIT_LIFETIME_PREFIX}#{limit_key}")
      expect(lifetime["blocked"].to_i).to eq(1)
    end

    it "increments blocked in bucketed and realtime keys" do
      described_class.record_blocked(limit_key)

      counts = redis.hgetall("#{described_class::LIMIT_COUNTS_PREFIX}#{limit_key}")
      total = counts.select { |k, _| k.start_with?("blocked:") }.values.sum(&:to_i)
      expect(total).to eq(1)

      realtime = redis.hgetall("#{described_class::LIMIT_REALTIME_COUNTS_PREFIX}#{limit_key}")
      rt_total = realtime.select { |k, _| k.start_with?("blocked:") }.values.sum(&:to_i)
      expect(rt_total).to eq(1)
    end

    it "records even when global metrics_enabled is false (caller gates)" do
      Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }
      described_class.record_blocked(limit_key)
      lifetime = redis.hgetall("#{described_class::LIMIT_LIFETIME_PREFIX}#{limit_key}")
      expect(lifetime["blocked"].to_i).to eq(1)
    end
  end

  describe ".record_override" do
    it "stores override metadata in Redis" do
      described_class.record_override("test_api", 100, 3600)

      meta = redis.hgetall("#{described_class::OVERRIDE_META_PREFIX}test_api")
      expect(meta["remaining"]).to eq("100")
      expect(meta["reset"]).to eq("3600")
      expect(meta["updated_at"].to_i).to be_within(2).of(Time.now.to_i)
    end

    it "sets TTL on override meta key" do
      described_class.record_override("test_api", 100, 3600)

      ttl = redis.ttl("#{described_class::OVERRIDE_META_PREFIX}test_api")
      expect(ttl).to be > 0
      expect(ttl).to be <= described_class::OVERRIDE_META_TTL
    end

    it "stores override history" do
      described_class.record_override("test_api", 100, 3600)

      history = redis.hgetall("#{described_class::OVERRIDE_HISTORY_PREFIX}test_api")
      expect(history).not_to be_empty
      expect(history.keys).to include(a_string_matching(/^remaining:/), a_string_matching(/^reset:/))
    end

    it "stores override realtime history" do
      described_class.record_override("test_api", 100, 3600)

      realtime = redis.hgetall("#{described_class::OVERRIDE_REALTIME_HISTORY_PREFIX}test_api")
      expect(realtime).not_to be_empty
    end

    it "records even when global metrics_enabled is false (caller gates)" do
      Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }
      described_class.record_override("test_api", 100, 3600)
      meta = redis.hgetall("#{described_class::OVERRIDE_META_PREFIX}test_api")
      expect(meta["remaining"]).to eq("100")
    end

    it "returns nil when registry is nil" do
      expect(described_class.record_override(nil, 100, 3600)).to be_nil
    end

    it "returns nil when registry is empty string" do
      expect(described_class.record_override("", 100, 3600)).to be_nil
    end
  end

  describe ".record_registry_meta" do
    it "records limit metadata with registry extracted from key_prefix" do
      described_class.record_registry_meta(
        registry_limit_key, key_prefix, 10, 30, "ApiClient", "fetch"
      )

      meta = redis.hgetall("#{described_class::LIMIT_META_PREFIX}#{registry_limit_key}")
      expect(meta).to include(
        "key_prefix" => key_prefix,
        "rate" => "10",
        "interval" => "30",
        "klass_name" => "ApiClient",
        "method" => "fetch",
        "registry" => "test_api"
      )
    end

    it "records even when global metrics_enabled is false (caller gates)" do
      Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }
      described_class.record_registry_meta(
        registry_limit_key, key_prefix, 10, 30, "ApiClient", "fetch"
      )
      meta = redis.hgetall("#{described_class::LIMIT_META_PREFIX}#{registry_limit_key}")
      expect(meta["rate"]).to eq("10")
    end
  end

  describe ".registry_from_key_prefix" do
    it "extracts registry name from a registry key prefix" do
      expect(described_class.registry_from_key_prefix(
               "hanikamu:rate_limit:rate_queue:registry:my_api"
             )).to eq("my_api")
    end

    it "returns nil for non-registry key prefixes" do
      expect(described_class.registry_from_key_prefix(
               "hanikamu:rate_limit:rate_queue:MyClass:call"
             )).to be_nil
    end
  end

  describe ".lifetime_snapshot" do
    it "returns allowed and blocked counts" do
      described_class.record_allowed(limit_key)
      described_class.record_allowed(limit_key)
      described_class.record_blocked(limit_key)

      snapshot = described_class.lifetime_snapshot(limit_key)
      expect(snapshot).to eq("allowed" => 2, "blocked" => 1)
    end

    it "returns zeros for unknown key" do
      snapshot = described_class.lifetime_snapshot("nonexistent:key")
      expect(snapshot).to eq("allowed" => 0, "blocked" => 0)
    end
  end

  describe ".history_snapshot" do
    it "returns bucketed allowed and blocked arrays with buckets" do
      described_class.record_allowed(limit_key)
      described_class.record_blocked(limit_key)

      snapshot = described_class.history_snapshot(limit_key)
      expect(snapshot).to have_key("buckets")
      expect(snapshot["buckets"]).to be_an(Array)
    end

    it "sums allowed and blocked to match recorded counts" do
      described_class.record_allowed(limit_key)
      described_class.record_blocked(limit_key)

      snapshot = described_class.history_snapshot(limit_key)
      expect(snapshot["allowed"].sum).to eq(1)
      expect(snapshot["blocked"].sum).to eq(1)
    end
  end

  describe ".realtime_history_snapshot" do
    it "returns bucketed data with realtime granularity" do
      described_class.record_allowed(limit_key)

      snapshot = described_class.realtime_history_snapshot(limit_key)
      expect(snapshot).to have_key("buckets")
      expect(snapshot["allowed"].sum).to eq(1)
    end
  end

  describe ".override_snapshot" do
    before do
      Hanikamu::RateLimit.register_limit(:test_api, rate: 10, interval: 30)
    end

    it "returns nil when registry is nil" do
      expect(described_class.override_snapshot(nil)).to be_nil
    end

    it "returns nil when registry is empty" do
      expect(described_class.override_snapshot("")).to be_nil
    end

    context "with a live override key" do
      before do
        Hanikamu::RateLimit.register_temporary_limit(:test_api, remaining: 50, reset: 120)
      end

      it "returns remaining, reset, and updated_at from the live key" do
        snapshot = described_class.override_snapshot("test_api")
        expect(snapshot).not_to be_nil
        expect(snapshot["remaining"]).to eq(50)
        expect(snapshot["reset"]).to be > 0
        expect(snapshot["updated_at"]).to be_within(2).of(Time.now.to_i)
      end
    end

    context "with stored override meta (no live key)" do
      before do
        now = Time.now.to_i
        redis.hset("#{described_class::OVERRIDE_META_PREFIX}stored_reg", {
                     "remaining" => "25",
                     "reset" => "300",
                     "updated_at" => now.to_s
                   })
      end

      it "returns data from stored meta" do
        snapshot = described_class.override_snapshot("stored_reg")
        expect(snapshot).not_to be_nil
        expect(snapshot["remaining"]).to eq(25)
        expect(snapshot["reset"]).to be > 0
      end
    end

    context "when stored override has expired" do
      before do
        past = Time.now.to_i - 600
        redis.hset("#{described_class::OVERRIDE_META_PREFIX}expired_reg", {
                     "remaining" => "25",
                     "reset" => "300",
                     "updated_at" => past.to_s
                   })
      end

      it "returns nil" do
        expect(described_class.override_snapshot("expired_reg")).to be_nil
      end
    end

    it "returns nil when no override exists" do
      expect(described_class.override_snapshot("test_api")).to be_nil
    end
  end

  describe ".override_history_snapshot" do
    it "returns nil for nil registry" do
      expect(described_class.override_history_snapshot(nil)).to be_nil
    end

    it "returns nil for empty registry" do
      expect(described_class.override_history_snapshot("")).to be_nil
    end

    it "returns bucketed remaining and reset arrays" do
      described_class.record_override("test_api", 100, 3600)

      snapshot = described_class.override_history_snapshot("test_api")
      expect(snapshot).to have_key("buckets")
      expect(snapshot).to have_key("remaining")
      expect(snapshot).to have_key("reset")
      expect(snapshot["remaining"].compact).to include(100)
      expect(snapshot["reset"].compact).to include(3600)
    end

    context "with realtime: true" do
      it "uses realtime bucket granularity" do
        described_class.record_override("test_api", 50, 120)

        snapshot = described_class.override_history_snapshot("test_api", realtime: true)
        expect(snapshot).to have_key("buckets")
        expect(snapshot["remaining"].compact).to include(50)
      end
    end
  end

  describe ".limit_snapshot" do
    before do
      described_class.record_limit(limit_key, {
                                     "rate" => "5", "interval" => "60.0",
                                     "key_prefix" => "test_prefix", "klass_name" => "TestClass",
                                     "method" => "call"
                                   })
    end

    it "returns a hash with limit metadata" do
      snapshot = described_class.limit_snapshot(limit_key)
      expect(snapshot).to include(
        "limit_key" => limit_key,
        "rate" => 5,
        "interval" => 60.0,
        "klass_name" => "TestClass",
        "method" => "call",
        "key_prefix" => "test_prefix"
      )
    end

    it "includes current_count and current_remaining" do
      snapshot = described_class.limit_snapshot(limit_key)
      expect(snapshot).to have_key("current_count")
      expect(snapshot).to have_key("current_remaining")
      expect(snapshot["current_remaining"]).to eq(5)
    end

    it "includes history and realtime_history" do
      snapshot = described_class.limit_snapshot(limit_key)
      expect(snapshot["history"]).to have_key("buckets")
      expect(snapshot["realtime_history"]).to have_key("buckets")
    end

    it "includes lifetime snapshot" do
      described_class.record_allowed(limit_key)
      snapshot = described_class.limit_snapshot(limit_key)
      expect(snapshot["lifetime"]["allowed"]).to eq(1)
    end

    it "returns nil for unknown limit key" do
      expect(described_class.limit_snapshot("nonexistent:key")).to be_nil
    end

    context "without registry" do
      it "sets override fields to nil" do
        snapshot = described_class.limit_snapshot(limit_key)
        expect(snapshot["override"]).to be_nil
        expect(snapshot["override_history"]).to be_nil
        expect(snapshot["override_realtime_history"]).to be_nil
      end
    end
  end

  describe ".limits_snapshot" do
    it "returns recorded limits" do
      described_class.record_limit(limit_key, {
                                     "rate" => "5", "interval" => "60.0",
                                     "key_prefix" => "test_prefix"
                                   })

      limits = described_class.limits_snapshot
      expect(limits).to be_an(Array)
      expect(limits.length).to be >= 1
      expect(limits.first["limit_key"]).to eq(limit_key)
    end

    it "merges registry limits" do
      Hanikamu::RateLimit.register_limit(:merge_test, rate: 10, interval: 30)

      limits = described_class.limits_snapshot
      registry_entry = limits.find { |l| l["registry"] == "merge_test" }
      expect(registry_entry).not_to be_nil
      expect(registry_entry["rate"]).to eq(10)
    end

    it "deduplicates recorded and registry limits by key_prefix" do
      Hanikamu::RateLimit.register_limit(:dedup_test, rate: 10, interval: 30)
      cfg = Hanikamu::RateLimit.fetch_limit(:dedup_test)
      lk = described_class.build_limit_key(cfg[:key_prefix], 10, 30.0)
      described_class.record_limit(lk, {
                                     "rate" => "10", "interval" => "30.0",
                                     "key_prefix" => cfg[:key_prefix], "registry" => "dedup_test"
                                   })

      limits = described_class.limits_snapshot
      matching = limits.select { |l| l["key_prefix"] == cfg[:key_prefix] }
      expect(matching.length).to eq(1)
    end
  end

  describe ".registry_limits_snapshot" do
    it "builds snapshots from registered limits" do
      Hanikamu::RateLimit.register_limit(:reg_snap, rate: 5, interval: 10)

      snapshots = described_class.registry_limits_snapshot
      snap = snapshots.find { |s| s["registry"] == "reg_snap" }
      expect(snap).not_to be_nil
      expect(snap["rate"]).to eq(5)
      expect(snap["interval"]).to eq(10.0)
    end
  end

  describe ".dashboard_payload" do
    it "returns a hash with config keys" do
      payload = described_class.dashboard_payload
      expect(payload).to have_key("generated_at")
      expect(payload).to have_key("bucket_seconds")
      expect(payload).to have_key("window_seconds")
      expect(payload).to have_key("metrics_realtime_bucket_seconds")
      expect(payload).to have_key("metrics_realtime_window_seconds")
    end

    it "includes redis info and limits" do
      payload = described_class.dashboard_payload
      expect(payload).to have_key("redis")
      expect(payload).to have_key("limits")
    end

    it "includes redis info" do
      payload = described_class.dashboard_payload
      expect(payload["redis"]).to include("version", "uptime", "used_memory_human")
    end

    it "returns limits sorted by key_prefix" do
      Hanikamu::RateLimit.register_limit(:zzz_api, rate: 1, interval: 1)
      Hanikamu::RateLimit.register_limit(:aaa_api, rate: 1, interval: 1)

      payload = described_class.dashboard_payload
      prefixes = payload["limits"].map { |l| l["key_prefix"] }
      expect(prefixes).to eq(prefixes.sort)
    end
  end

  describe ".redis_info" do
    it "returns a hash with Redis server info" do
      info = described_class.redis_info
      expect(info).to include(
        "version" => a_kind_of(String),
        "uptime" => a_kind_of(Integer),
        "connected_clients" => a_kind_of(Integer),
        "used_memory_human" => a_kind_of(String)
      )
    end
  end

  describe ".bucket_for" do
    it "floors timestamp to the nearest bucket boundary" do
      expect(described_class.bucket_for(1_000_007, 300)).to eq(999_900)
      expect(described_class.bucket_for(1_000_200, 300)).to eq(1_000_200)
      expect(described_class.bucket_for(1_000_299, 300)).to eq(1_000_200)
    end
  end

  describe ".buckets_for_window" do
    it "returns an array of bucket timestamps covering the window" do
      buckets = described_class.buckets_for_window(600, 300)
      expect(buckets).to be_an(Array)
      expect(buckets.length).to be >= 2
      # Consecutive buckets differ by bucket_seconds
      buckets.each_cons(2) { |a, b| expect(b - a).to eq(300) }
    end
  end

  describe ".ttl_window_seconds" do
    it "returns window + bucket_seconds" do
      expect(described_class.ttl_window_seconds(86_400, 300)).to eq(86_700)
    end
  end

  describe ".build_limit_key" do
    it "concatenates prefix, rate, and interval" do
      expect(described_class.build_limit_key("prefix", 10, 60.0)).to eq("prefix:10:60.0")
    end
  end

  describe ".merge_limits" do
    it "prefers recorded limits over registry limits with same key_prefix" do
      recorded = [{ "key_prefix" => "same", "source" => "recorded" }]
      registry = [{ "key_prefix" => "same", "source" => "registry" }]

      merged = described_class.merge_limits(recorded, registry)
      expect(merged.length).to eq(1)
      expect(merged.first["source"]).to eq("recorded")
    end

    it "includes both when key_prefixes differ" do
      recorded = [{ "key_prefix" => "a", "limit_key" => "a" }]
      registry = [{ "key_prefix" => "b", "limit_key" => "b" }]

      merged = described_class.merge_limits(recorded, registry)
      expect(merged.length).to eq(2)
    end
  end

  describe "metrics_enabled flag" do
    describe "recorded entries (entry_from_meta)" do
      it "inherits global metrics_enabled when no registry is set" do
        Hanikamu::RateLimit.configure { |c| c.metrics_enabled = true }
        described_class.record_limit(limit_key, {
                                       "rate" => "5", "interval" => "60.0",
                                       "key_prefix" => "test_prefix",
                                       "klass_name" => "TestClass", "method" => "call"
                                     })

        limits = described_class.limits_snapshot
        entry = limits.find { |l| l["limit_key"] == limit_key }
        expect(entry).not_to be_nil
        expect(entry["metrics_enabled"]).to be true
      end

      it "returns false when global metrics_enabled is false and no registry" do
        Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }
        described_class.record_limit(limit_key, {
                                       "rate" => "5", "interval" => "60.0",
                                       "key_prefix" => "test_prefix"
                                     })

        limits = described_class.limits_snapshot
        entry = limits.find { |l| l["limit_key"] == limit_key }
        expect(entry).not_to be_nil
        expect(entry["metrics_enabled"]).to be false
      end

      it "inherits per-registry metrics override (true) over global false" do
        Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }
        Hanikamu::RateLimit.register_limit(:metrics_on, rate: 5, interval: 10, metrics: true)
        cfg = Hanikamu::RateLimit.fetch_limit(:metrics_on)
        lk = described_class.build_limit_key(cfg[:key_prefix], 5, 10.0)

        described_class.record_limit(lk, {
                                       "rate" => "5", "interval" => "10.0",
                                       "key_prefix" => cfg[:key_prefix],
                                       "registry" => "metrics_on"
                                     })

        limits = described_class.limits_snapshot
        entry = limits.find { |l| l["limit_key"] == lk }
        expect(entry).not_to be_nil
        expect(entry["metrics_enabled"]).to be true
      end

      it "inherits per-registry metrics override (false) over global true" do
        Hanikamu::RateLimit.configure { |c| c.metrics_enabled = true }
        Hanikamu::RateLimit.register_limit(:metrics_off, rate: 5, interval: 10, metrics: false)
        cfg = Hanikamu::RateLimit.fetch_limit(:metrics_off)
        lk = described_class.build_limit_key(cfg[:key_prefix], 5, 10.0)

        described_class.record_limit(lk, {
                                       "rate" => "5", "interval" => "10.0",
                                       "key_prefix" => cfg[:key_prefix],
                                       "registry" => "metrics_off"
                                     })

        limits = described_class.limits_snapshot
        entry = limits.find { |l| l["limit_key"] == lk }
        expect(entry).not_to be_nil
        expect(entry["metrics_enabled"]).to be false
      end
    end

    describe "registry entries (build_registry_entries)" do
      it "uses per-registry metrics: true over global false" do
        Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }
        Hanikamu::RateLimit.register_limit(:reg_on, rate: 3, interval: 5, metrics: true)

        limits = described_class.limits_snapshot
        entry = limits.find { |l| l["registry"] == "reg_on" }
        expect(entry).not_to be_nil
        expect(entry["metrics_enabled"]).to be true
      end

      it "uses per-registry metrics: false over global true" do
        Hanikamu::RateLimit.configure { |c| c.metrics_enabled = true }
        Hanikamu::RateLimit.register_limit(:reg_off, rate: 3, interval: 5, metrics: false)

        limits = described_class.limits_snapshot
        entry = limits.find { |l| l["registry"] == "reg_off" }
        expect(entry).not_to be_nil
        expect(entry["metrics_enabled"]).to be false
      end

      it "falls back to global when per-registry metrics is nil" do
        Hanikamu::RateLimit.configure { |c| c.metrics_enabled = true }
        Hanikamu::RateLimit.register_limit(:reg_nil, rate: 3, interval: 5)

        limits = described_class.limits_snapshot
        entry = limits.find { |l| l["registry"] == "reg_nil" }
        expect(entry).not_to be_nil
        expect(entry["metrics_enabled"]).to be true
      end
    end

    describe "stale / unknown registry resilience" do
      it "falls back to global when recorded meta references a removed registry" do
        Hanikamu::RateLimit.configure { |c| c.metrics_enabled = true }

        described_class.record_limit(limit_key, {
                                       "rate" => "5", "interval" => "60.0",
                                       "key_prefix" => "test_prefix",
                                       "registry" => "removed_registry"
                                     })

        limits = described_class.limits_snapshot
        entry = limits.find { |l| l["limit_key"] == limit_key }
        expect(entry).not_to be_nil
        expect(entry["metrics_enabled"]).to be true
      end

      it "returns false fallback when global is false and registry is unknown" do
        Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }

        described_class.record_limit(limit_key, {
                                       "rate" => "5", "interval" => "60.0",
                                       "key_prefix" => "test_prefix",
                                       "registry" => "nonexistent_registry"
                                     })

        limits = described_class.limits_snapshot
        entry = limits.find { |l| l["limit_key"] == limit_key }
        expect(entry).not_to be_nil
        expect(entry["metrics_enabled"]).to be false
      end

      it "does not raise when resolve_effective_metrics encounters an unknown registry" do
        expect { described_class.send(:resolve_effective_metrics, "totally_unknown") }
          .not_to raise_error
      end
    end
  end
end
