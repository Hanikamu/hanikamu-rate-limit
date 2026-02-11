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

    it "defaults interval to 60 when omitted" do
      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name
          "LimiterDefaultIntervalClass"
        end

        def self.capture_rate_queue(queue)
          @captured_queue = queue
        end

        class << self
          attr_reader :captured_queue
        end
      end

      allow(klass).to receive(:install_rate_limited_method) do |_, queue|
        klass.capture_rate_queue(queue)
      end

      klass.limit_method(:execute, rate: 5)

      interval_value = klass.captured_queue.instance_variable_get(:@interval)
      expect(interval_value).to eq(60.0)
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

  describe "#limit_method with registry" do
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

        limit_method :execute, registry: :external_api

        def execute
          # no-op
        end
      end

      klass_two = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name
          "RegistryTwo"
        end

        limit_method :execute, registry: :external_api

        def execute
          # no-op
        end
      end

      klass_one.new.execute

      expect do
        klass_two.new.execute
      end.to raise_error(Hanikamu::RateLimit::RateLimitError)
    end

    it "raises ArgumentError when combining registry with rate" do
      expect do
        Class.new do
          extend Hanikamu::RateLimit::Mixin

          def self.name = "BadCombo"
          limit_method :execute, registry: :external_api, rate: 5
          def execute; end
        end
      end.to raise_error(ArgumentError, /registry: must be used alone/)
    end

    it "raises ArgumentError when combining registry with interval" do
      expect do
        Class.new do
          extend Hanikamu::RateLimit::Mixin

          def self.name = "BadCombo2"
          limit_method :execute, registry: :external_api, interval: 1.0
          def execute; end
        end
      end.to raise_error(ArgumentError, /registry: must be used alone/)
    end

    it "raises ArgumentError when combining registry with check_interval" do
      expect do
        Class.new do
          extend Hanikamu::RateLimit::Mixin

          def self.name = "BadCombo3"
          limit_method :execute, registry: :external_api, check_interval: 0.1
          def execute; end
        end
      end.to raise_error(ArgumentError, /registry: must be used alone/)
    end

    it "raises ArgumentError when combining registry with max_wait_time" do
      expect do
        Class.new do
          extend Hanikamu::RateLimit::Mixin

          def self.name = "BadCombo4"
          limit_method :execute, registry: :external_api, max_wait_time: 1.0
          def execute; end
        end
      end.to raise_error(ArgumentError, /registry: must be used alone/)
    end

    it "raises ArgumentError when neither registry nor rate is provided" do
      expect do
        Class.new do
          extend Hanikamu::RateLimit::Mixin

          def self.name = "NoArgs"
          limit_method :execute
          def execute; end
        end
      end.to raise_error(ArgumentError, /Either registry: or rate: must be provided/)
    end

    context "with an active override" do
      let(:override_key) { Hanikamu::RateLimit.override_key_for(:external_api) }

      after do
        redis.del(override_key)
      end

      it "uses the override instead of the registered limit" do
        Hanikamu::RateLimit.register_temporary_limit(:external_api, remaining: 5, reset: 5)

        klass = Class.new do
          extend Hanikamu::RateLimit::Mixin

          def self.name
            "OverrideTestClass"
          end

          limit_method :execute, registry: :external_api

          def execute
            "executed"
          end
        end

        # Registry limit is rate: 1, but override allows 5
        5.times do
          expect(klass.new.execute).to eq("executed")
        end
      end

      it "resumes normal limits after override expires" do
        Hanikamu::RateLimit.register_temporary_limit(:external_api, remaining: 2, reset: 1)

        klass = Class.new do
          extend Hanikamu::RateLimit::Mixin

          def self.name
            "OverrideExpiryClass"
          end

          limit_method :execute, registry: :external_api

          def execute
            "executed"
          end
        end

        # Use up the override
        2.times { klass.new.execute }

        # Wait for override to expire
        expect(wait_until? { !redis.exists?(override_key) }).to be(true)

        # Should be back to normal registry limit (rate: 1)
        expect(klass.new.execute).to eq("executed")

        expect do
          klass.new.execute
        end.to raise_error(Hanikamu::RateLimit::RateLimitError)
      end
    end
  end
end
