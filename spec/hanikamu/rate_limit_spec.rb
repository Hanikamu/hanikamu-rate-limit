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
end
