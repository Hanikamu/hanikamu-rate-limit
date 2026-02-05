# frozen_string_literal: true

RSpec.describe Hanikamu::RateLimit::Mixin do
  let(:redis_url) { ENV.fetch("REDIS_URL", "redis://localhost:6379/15") }
  let(:redis) { Redis.new(url: redis_url) }
  let(:test_class) do
    Class.new do
      extend Hanikamu::RateLimit::Mixin

      def self.name
        "TestService"
      end

      def execute
        "executed"
      end

      attr_accessor :rate_queue

      def self.capture_rate_queue(queue)
        @captured_queue = queue
      end

      class << self
        attr_reader :captured_queue
      end
    end
  end

  let(:rate) { 2 }
  let(:interval) { 5.0 }
  let(:check_interval_param) { nil }
  let(:max_wait_time_param) { nil }

  before do
    Hanikamu::RateLimit.configure do |config|
      config.redis_url = redis_url
      config.max_wait_time = 2.0
      config.check_interval = 0.5
    end

    redis.flushdb
  end

  after do
    redis.flushdb
  end

  describe "#limit_method" do
    subject do
      params = { rate:, interval: }
      params[:check_interval] = check_interval_param unless check_interval_param.nil?
      params[:max_wait_time] = max_wait_time_param unless max_wait_time_param.nil?
      test_class.limit_method :execute, **params
    end

    it "passes arguments to the original method" do
      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name
          "LimiterArgsClass"
        end

        attr_reader :last_arg

        limit_method :process, rate: 10, interval: 1

        def process(value)
          @last_arg = value
        end
      end

      instance = klass.new
      instance.process("test_value")

      expect(instance.last_arg).to eq("test_value")
    end

    it "passes keyword arguments to the original method" do
      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name
          "LimiterKwargsClass"
        end

        attr_reader :last_kwarg

        limit_method :process, rate: 10, interval: 1

        def process(value:)
          @last_kwarg = value
        end
      end

      instance = klass.new
      instance.process(value: "test_value")

      expect(instance.last_kwarg).to eq("test_value")
    end

    it "creates a reset method" do
      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name
          "LimiterResetClass"
        end

        limit_method :tick, rate: 2, interval: 0.2, max_wait_time: 0.1

        def tick
          # no-op
        end
      end

      instance = klass.new
      2.times { instance.tick }

      expect do
        instance.tick
      end.to raise_error(Hanikamu::RateLimit::RateLimitError)

      expect(klass).to respond_to(:reset_tick_limit!)
      klass.reset_tick_limit!

      expect { instance.tick }.not_to raise_error
    end

    it "calls the block when rate limit is hit" do
      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name
          "LimiterBlockClass"
        end

        @block_count = 0

        limit_method :execute, rate: 1, interval: 0.2, max_wait_time: 0.1 do
          @block_count += 1
        end

        class << self
          attr_reader :block_count
        end

        def execute
          # no-op
        end
      end

      instance = klass.new

      expect do
        2.times { instance.execute }
      end.to raise_error(Hanikamu::RateLimit::RateLimitError)

      expect(klass.block_count).to be >= 1
    end

    it "uses config defaults for max_wait_time and check_interval" do
      subject

      rate.times { test_class.new.execute }

      start_time = Time.now
      expect do
        test_class.new.execute
      end.to raise_error(Hanikamu::RateLimit::RateLimitError, /Max wait time exceeded/)
      elapsed = Time.now - start_time

      expect(elapsed).to be_within(0.1).of(2.0)
    end

    context "when check_interval is provided" do
      let(:check_interval_param) { 0.2 }

      it "uses provided check_interval and config default for max_wait_time" do
        subject

        rate.times { test_class.new.execute }

        start_time = Time.now
        expect do
          test_class.new.execute
        end.to raise_error(Hanikamu::RateLimit::RateLimitError, /Max wait time exceeded/)
        elapsed = Time.now - start_time

        expect(elapsed).to be_within(0.1).of(2.0)
      end
    end

    context "when max_wait_time is provided" do
      let(:max_wait_time_param) { 1.0 }

      it "uses provided max_wait_time and config default for check_interval" do
        subject

        rate.times { test_class.new.execute }

        start_time = Time.now
        expect do
          test_class.new.execute
        end.to raise_error(Hanikamu::RateLimit::RateLimitError, /Max wait time exceeded/)
        elapsed = Time.now - start_time

        expect(elapsed).to be_within(0.1).of(1.0)
      end
    end

    context "when both check_interval and max_wait_time are provided" do
      let(:check_interval_param) { 0.1 }
      let(:max_wait_time_param) { 0.5 }

      it "uses provided values instead of config defaults" do
        subject

        rate.times { test_class.new.execute }

        start_time = Time.now
        expect do
          test_class.new.execute
        end.to raise_error(Hanikamu::RateLimit::RateLimitError, /Max wait time exceeded/)
        elapsed = Time.now - start_time

        expect(elapsed).to be_within(0.1).of(0.5)
      end
    end

    context "when config defaults are changed" do
      before do
        Hanikamu::RateLimit.configure do |config|
          config.max_wait_time = 1.5
          config.check_interval = 0.1
        end
      end

      it "uses the new config defaults" do
        subject

        rate.times { test_class.new.execute }

        start_time = Time.now
        expect do
          test_class.new.execute
        end.to raise_error(Hanikamu::RateLimit::RateLimitError, /Max wait time exceeded/)
        elapsed = Time.now - start_time

        expect(elapsed).to be_within(0.1).of(1.5)
      end
    end
  end

  describe "#limit_with" do
    before do
      Hanikamu::RateLimit.reset_registry!
      Hanikamu::RateLimit.register_limit(
        :external_api,
        rate: 1,
        interval: 0.2,
        check_interval: 0.05,
        max_wait_time: 0.05
      )
    end

    it "shares limits across classes using the same registry" do
      klass_one = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name
          "RegistryOne"
        end

        limit_with :execute, registry: :external_api

        def execute
          # no-op
        end
      end

      klass_two = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name
          "RegistryTwo"
        end

        limit_with :execute, registry: :external_api

        def execute
          # no-op
        end
      end

      klass_one.new.execute

      expect do
        klass_two.new.execute
      end.to raise_error(Hanikamu::RateLimit::RateLimitError)
    end
  end
end
