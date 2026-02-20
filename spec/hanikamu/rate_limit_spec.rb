# frozen_string_literal: true

RSpec.describe Hanikamu::RateLimit do
  let(:redis_url) { ENV.fetch("REDIS_URL", "redis://localhost:6379/15") }

  describe "configuration" do
    before do
      described_class.configure do |config|
        config.redis_url = redis_url
        config.max_wait_time = 2.0
        config.check_interval = 0.5
      end
    end

    after do
      described_class.configure do |config|
        config.redis_url = redis_url
        config.max_wait_time = 2.0
        config.check_interval = 0.5
      end
    end

    it "has default max_wait_time of 2.0" do
      expect(described_class.config.max_wait_time).to eq(2.0)
    end

    it "has default check_interval of 0.5" do
      expect(described_class.config.check_interval).to eq(0.5)
    end

    it "allows setting custom max_wait_time" do
      described_class.configure do |config|
        config.max_wait_time = 1.5
      end

      expect(described_class.config.max_wait_time).to eq(1.5)
    end

    it "allows setting custom check_interval" do
      described_class.configure do |config|
        config.check_interval = 0.2
      end

      expect(described_class.config.check_interval).to eq(0.2)
    end

    it "allows setting both values together" do
      described_class.configure do |config|
        config.max_wait_time = 3.0
        config.check_interval = 0.1
      end

      expect(described_class.config.max_wait_time).to eq(3.0)
      expect(described_class.config.check_interval).to eq(0.1)
    end

    it "registers named limits through config" do
      described_class.reset_registry!

      described_class.configure do |config|
        config.register_limit(:external_api, rate: 5, interval: 0.5)
      end

      registered = described_class.fetch_limit(:external_api)
      expect(registered[:rate]).to eq(5)
      expect(registered[:interval]).to eq(0.5)
    end

    it "raises ArgumentError when key_prefix is provided" do
      described_class.reset_registry!

      expect do
        described_class.register_limit(:external_api, rate: 5, interval: 0.5, key_prefix: "custom")
      end.to raise_error(ArgumentError, /unknown keyword: :key_prefix/)
    end

    it "normalizes registry names so strings map to symbols" do
      described_class.reset_registry!

      described_class.register_limit("External Api", rate: 5, interval: 0.5)

      registered = described_class.fetch_limit(:external_api)
      expect(registered[:rate]).to eq(5)
    end

    it "has metrics_enabled false by default" do
      expect(described_class.config.metrics_enabled).to be(false)
    end

    it "allows enabling metrics globally" do
      described_class.configure do |config|
        config.metrics_enabled = true
      end

      expect(described_class.config.metrics_enabled).to be(true)

      described_class.configure do |config|
        config.metrics_enabled = false
      end
    end

    it "stores metrics option in registered limits" do
      described_class.reset_registry!

      described_class.configure do |config|
        config.register_limit(:no_metrics_api, rate: 5, interval: 0.5, metrics: false)
      end

      registered = described_class.fetch_limit(:no_metrics_api)
      expect(registered[:metrics]).to be(false)
    end

    it "omits metrics key from registered limits when not specified" do
      described_class.reset_registry!

      described_class.configure do |config|
        config.register_limit(:default_metrics_api, rate: 5, interval: 0.5)
      end

      registered = described_class.fetch_limit(:default_metrics_api)
      expect(registered).not_to have_key(:metrics)
    end
  end

  describe ".register_temporary_limit" do
    let(:redis) { Redis.new(url: redis_url) }

    before do
      described_class.reset_registry!
      described_class.configure do |config|
        config.redis_url = redis_url
        config.register_limit(:external_api, rate: 5, interval: 0.5)
      end
    end

    after do
      described_class.instance_variable_set(:@redis_client, nil)
      redis.del(described_class.override_key_for(:external_api))
    end

    it "sets an override key in Redis with remaining count and TTL" do
      result = described_class.register_temporary_limit(:external_api, remaining: 175, reset: 60)
      expect(result).to be(true)

      key = described_class.override_key_for(:external_api)
      expect(redis.get(key).to_i).to eq(175)
      ttl = redis.ttl(key)
      expect(ttl).to be > 0
      expect(ttl).to be <= 60
    end

    it "raises ArgumentError for unknown registry" do
      expect do
        described_class.register_temporary_limit(:unknown, remaining: 10, reset: 5)
      end.to raise_error(ArgumentError, /Unknown registered limit/)
    end

    it "returns false and does not write to Redis when reset is non-positive" do
      key = described_class.override_key_for(:external_api)

      result = described_class.register_temporary_limit(:external_api, remaining: 10, reset: 0)
      expect(result).to be(false)
      expect(redis.exists?(key)).to be(false)

      result = described_class.register_temporary_limit(:external_api, remaining: 10, reset: -5)
      expect(result).to be(false)
      expect(redis.exists?(key)).to be(false)
    end

    it "returns false and does not write to Redis when remaining is negative" do
      key = described_class.override_key_for(:external_api)

      result = described_class.register_temporary_limit(:external_api, remaining: -1, reset: 5)
      expect(result).to be(false)
      expect(redis.exists?(key)).to be(false)
    end

    it "returns false and does not write to Redis when remaining or reset is nil" do
      key = described_class.override_key_for(:external_api)

      result = described_class.register_temporary_limit(:external_api, remaining: nil, reset: 5)
      expect(result).to be(false)
      expect(redis.exists?(key)).to be(false)

      result = described_class.register_temporary_limit(:external_api, remaining: 5, reset: nil)
      expect(result).to be(false)
      expect(redis.exists?(key)).to be(false)
    end

    it "returns false and does not write to Redis when remaining or reset is non-numeric" do
      key = described_class.override_key_for(:external_api)

      result = described_class.register_temporary_limit(:external_api, remaining: "abc", reset: 5)
      expect(result).to be(false)
      expect(redis.exists?(key)).to be(false)

      result = described_class.register_temporary_limit(:external_api, remaining: 5, reset: "abc")
      expect(result).to be(false)
      expect(redis.exists?(key)).to be(false)
    end

    it "overwrites a previous override" do
      described_class.register_temporary_limit(:external_api, remaining: 100, reset: 60)
      described_class.register_temporary_limit(:external_api, remaining: 50, reset: 30)

      key = described_class.override_key_for(:external_api)
      expect(redis.get(key).to_i).to eq(50)
      ttl = redis.ttl(key)
      expect(ttl).to be > 0
      expect(ttl).to be <= 30
    end

    it "unwraps array values (e.g. from HTTParty headers.to_h)" do
      result = described_class.register_temporary_limit(:external_api, remaining: ["99"], reset: ["10"])
      expect(result).to be(true)

      key = described_class.override_key_for(:external_api)
      expect(redis.get(key).to_i).to eq(99)
      ttl = redis.ttl(key)
      expect(ttl).to be > 0
      expect(ttl).to be <= 10
    end

    it "accepts plain string values" do
      result = described_class.register_temporary_limit(:external_api, remaining: "175", reset: "60")
      expect(result).to be(true)

      key = described_class.override_key_for(:external_api)
      expect(redis.get(key).to_i).to eq(175)
    end

    it "reuses the Redis client across calls" do
      pipeline_double = instance_double(Redis, set: true, hset: true, expire: true)
      redis_double = instance_double(Redis, set: true, close: nil, del: nil, hset: true, expire: true)
      allow(redis_double).to receive(:pipelined).and_yield(pipeline_double)
      allow(Redis).to receive(:new).and_return(redis_double)

      described_class.instance_variable_set(:@redis_client, nil)

      described_class.register_temporary_limit(:external_api, remaining: 10, reset: 5)
      described_class.register_temporary_limit(:external_api, remaining: 20, reset: 5)

      expect(Redis).to have_received(:new).once
      expect(redis_double).to have_received(:set).twice
    end

    context "with reset_kind: :seconds (default)" do
      it "uses the reset value directly as TTL" do
        result = described_class.register_temporary_limit(:external_api, remaining: 50, reset: 30, reset_kind: :seconds)
        expect(result).to be(true)

        key = described_class.override_key_for(:external_api)
        expect(redis.get(key).to_i).to eq(50)
        ttl = redis.ttl(key)
        expect(ttl).to be > 0
        expect(ttl).to be <= 30
      end

      it "behaves the same when reset_kind is omitted" do
        result = described_class.register_temporary_limit(:external_api, remaining: 50, reset: 30)
        expect(result).to be(true)

        key = described_class.override_key_for(:external_api)
        expect(redis.get(key).to_i).to eq(50)
        ttl = redis.ttl(key)
        expect(ttl).to be > 0
        expect(ttl).to be <= 30
      end
    end

    context "with reset_kind: :unix" do
      it "converts a Unix timestamp to a TTL in seconds" do
        future_timestamp = Time.now.to_i + 45
        result = described_class.register_temporary_limit(
          :external_api, remaining: 80, reset: future_timestamp, reset_kind: :unix
        )
        expect(result).to be(true)

        key = described_class.override_key_for(:external_api)
        expect(redis.get(key).to_i).to eq(80)
        ttl = redis.ttl(key)
        expect(ttl).to be > 0
        expect(ttl).to be <= 45
      end

      it "returns false when the Unix timestamp is in the past" do
        past_timestamp = Time.now.to_i - 10
        result = described_class.register_temporary_limit(
          :external_api, remaining: 80, reset: past_timestamp, reset_kind: :unix
        )
        expect(result).to be(false)
      end

      it "accepts string Unix timestamps (e.g. from HTTP headers)" do
        future_timestamp = (Time.now.to_i + 30).to_s
        result = described_class.register_temporary_limit(
          :external_api, remaining: "50", reset: future_timestamp, reset_kind: :unix
        )
        expect(result).to be(true)

        key = described_class.override_key_for(:external_api)
        expect(redis.get(key).to_i).to eq(50)
      end

      it "accepts array-wrapped Unix timestamps" do
        future_timestamp = [(Time.now.to_i + 20).to_s]
        result = described_class.register_temporary_limit(
          :external_api, remaining: ["60"], reset: future_timestamp, reset_kind: :unix
        )
        expect(result).to be(true)

        key = described_class.override_key_for(:external_api)
        expect(redis.get(key).to_i).to eq(60)
      end

      it "returns false for non-numeric reset value" do
        result = described_class.register_temporary_limit(
          :external_api, remaining: 10, reset: "abc", reset_kind: :unix
        )
        expect(result).to be(false)
      end
    end

    context "with reset_kind: :datetime" do
      it "converts a Time object to a TTL in seconds" do
        future_time = Time.now + 40
        result = described_class.register_temporary_limit(
          :external_api, remaining: 70, reset: future_time, reset_kind: :datetime
        )
        expect(result).to be(true)

        key = described_class.override_key_for(:external_api)
        expect(redis.get(key).to_i).to eq(70)
        ttl = redis.ttl(key)
        expect(ttl).to be > 0
        expect(ttl).to be <= 40
      end

      it "converts a DateTime object to a TTL in seconds" do
        future_time = Time.now + 35
        future_datetime = DateTime.parse(future_time.to_s)
        result = described_class.register_temporary_limit(
          :external_api, remaining: 60, reset: future_datetime, reset_kind: :datetime
        )
        expect(result).to be(true)

        key = described_class.override_key_for(:external_api)
        expect(redis.get(key).to_i).to eq(60)
        ttl = redis.ttl(key)
        expect(ttl).to be > 0
        expect(ttl).to be <= 35
      end

      it "returns false when the datetime is in the past" do
        past_time = Time.now - 10
        result = described_class.register_temporary_limit(
          :external_api, remaining: 50, reset: past_time, reset_kind: :datetime
        )
        expect(result).to be(false)
      end

      it "returns false for nil reset" do
        result = described_class.register_temporary_limit(
          :external_api, remaining: 50, reset: nil, reset_kind: :datetime
        )
        expect(result).to be(false)
      end

      it "returns false for non-Time/DateTime types" do
        result = described_class.register_temporary_limit(
          :external_api, remaining: 50, reset: 12_345, reset_kind: :datetime
        )
        expect(result).to be(false)
      end

      it "returns false for string values" do
        result = described_class.register_temporary_limit(
          :external_api, remaining: 50, reset: "2026-01-01T00:00:00Z", reset_kind: :datetime
        )
        expect(result).to be(false)
      end
    end

    context "with reset_kind: :seconds overflow protection" do
      it "raises ArgumentError when seconds value looks like a Unix timestamp" do
        expect do
          described_class.register_temporary_limit(
            :external_api, remaining: 10, reset: 1_740_000_000, reset_kind: :seconds
          )
        end.to raise_error(ArgumentError, /exceeds MAX_SECONDS_TTL/)
      end

      it "raises ArgumentError when string seconds value exceeds max" do
        expect do
          described_class.register_temporary_limit(
            :external_api, remaining: 10, reset: "100000", reset_kind: :seconds
          )
        end.to raise_error(ArgumentError, /exceeds MAX_SECONDS_TTL/)
      end

      it "allows seconds at the boundary (86400)" do
        result = described_class.register_temporary_limit(
          :external_api, remaining: 10, reset: 86_400, reset_kind: :seconds
        )
        expect(result).to be(true)
      end

      it "raises for one second over the boundary" do
        expect do
          described_class.register_temporary_limit(
            :external_api, remaining: 10, reset: 86_401, reset_kind: :seconds
          )
        end.to raise_error(ArgumentError, /exceeds MAX_SECONDS_TTL/)
      end
    end

    context "with invalid reset_kind" do
      it "raises ArgumentError" do
        expect do
          described_class.register_temporary_limit(:external_api, remaining: 10, reset: 5, reset_kind: :invalid)
        end.to raise_error(ArgumentError, /Invalid reset_kind/)
      end

      it "includes valid options in the error message" do
        expect do
          described_class.register_temporary_limit(:external_api, remaining: 10, reset: 5, reset_kind: :timestamp)
        end.to raise_error(ArgumentError, /seconds, unix, datetime/)
      end
    end
  end

  describe ".override_key_for" do
    it "returns a deterministic key based on the registry name" do
      key = described_class.override_key_for(:external_api)
      expect(key).to eq("hanikamu:rate_limit:rate_queue:registry:external_api:override")
    end

    it "normalizes names consistently across strings and symbols" do
      expect(described_class.override_key_for("External Api"))
        .to eq(described_class.override_key_for(:external_api))
    end
  end

  describe ".reset_limit!" do
    let(:redis) { Redis.new(url: redis_url) }

    before do
      described_class.instance_variable_set(:@redis_client, nil)
      described_class.reset_registry!
      described_class.configure do |config|
        config.redis_url = redis_url
        config.register_limit(:resettable_api, rate: 10, interval: 60)
      end
    end

    it "deletes the sliding window key from Redis and returns true" do
      cfg = described_class.fetch_limit(:resettable_api)
      limit_key = "#{cfg[:key_prefix]}:#{cfg[:rate]}:#{cfg[:interval].to_f}"

      # Seed the key so we can verify deletion
      redis.zadd(limit_key, Time.now.to_f, SecureRandom.uuid)
      expect(redis.exists?(limit_key)).to be(true)

      result = described_class.reset_limit!(:resettable_api)
      expect(result).to be(true)
      expect(redis.exists?(limit_key)).to be(false)
    end

    it "also deletes the override key" do
      override_key = described_class.override_key_for(:resettable_api)
      redis.set(override_key, 5, ex: 60)
      expect(redis.exists?(override_key)).to be(true)

      described_class.reset_limit!(:resettable_api)
      expect(redis.exists?(override_key)).to be(false)
    end

    it "raises ArgumentError for an unknown limit" do
      expect do
        described_class.reset_limit!(:unknown_limit)
      end.to raise_error(ArgumentError, /Unknown registered limit/)
    end
  end
end
