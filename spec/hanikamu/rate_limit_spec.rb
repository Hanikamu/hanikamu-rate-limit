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
  end
end
