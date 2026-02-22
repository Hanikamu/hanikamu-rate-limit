# frozen_string_literal: true

# Custom error class for testing AIMD error handling.
class TestApiError < StandardError; end

RSpec.describe "Adaptive rate limiting (AIMD integration)" do # rubocop:disable RSpec/DescribeClass
  let(:redis_url) { ENV.fetch("REDIS_URL", "redis://localhost:6379/15") }
  let(:redis) { Redis.new(url: redis_url) }

  before do
    Hanikamu::RateLimit.reset_registry!
    Hanikamu::RateLimit.configure do |config|
      config.redis_url = redis_url
      config.max_wait_time = 2.0
      config.check_interval = 0.1
    end
    scan_and_delete(redis, "hanikamu:rate_limit:*")
  end

  after do
    scan_and_delete(redis, "hanikamu:rate_limit:*")
    Hanikamu::RateLimit.reset_registry!
  end

  describe "register_adaptive_limit via configure block" do
    it "registers through the config helper" do
      Hanikamu::RateLimit.configure do |config|
        config.register_adaptive_limit(
          :test_api,
          initial_rate: 5, interval: 1,
          error_classes: [TestApiError]
        )
      end

      cfg = Hanikamu::RateLimit.fetch_limit(:test_api)
      expect(cfg[:adaptive]).to be(true)
      expect(cfg[:rate]).to eq(5)
      expect(cfg[:initial_rate]).to eq(5)
    end
  end

  describe "validation" do
    it "rejects non-positive initial_rate" do
      expect do
        Hanikamu::RateLimit.register_adaptive_limit(:bad, initial_rate: 0, interval: 1)
      end.to raise_error(ArgumentError, /initial_rate/)
    end

    it "rejects min_rate > initial_rate" do
      expect do
        Hanikamu::RateLimit.register_adaptive_limit(:bad, initial_rate: 5, interval: 1, min_rate: 10)
      end.to raise_error(ArgumentError, /min_rate/)
    end

    it "rejects max_rate < initial_rate" do
      expect do
        Hanikamu::RateLimit.register_adaptive_limit(:bad, initial_rate: 5, interval: 1, max_rate: 3)
      end.to raise_error(ArgumentError, /max_rate/)
    end

    it "rejects decrease_factor outside (0,1)" do
      expect do
        Hanikamu::RateLimit.register_adaptive_limit(:bad, initial_rate: 5, interval: 1, decrease_factor: 1.5)
      end.to raise_error(ArgumentError, /decrease_factor/)
    end

    it "rejects non-positive increase_by" do
      expect do
        Hanikamu::RateLimit.register_adaptive_limit(:bad, initial_rate: 5, interval: 1, increase_by: 0)
      end.to raise_error(ArgumentError, /increase_by/)
    end

    it "rejects non-positive probe_window" do
      expect do
        Hanikamu::RateLimit.register_adaptive_limit(:bad, initial_rate: 5, interval: 1, probe_window: -1)
      end.to raise_error(ArgumentError, /probe_window/)
    end

    it "rejects non-positive cooldown_after_decrease" do
      expect do
        Hanikamu::RateLimit.register_adaptive_limit(:bad, initial_rate: 5, interval: 1, cooldown_after_decrease: 0)
      end.to raise_error(ArgumentError, /cooldown_after_decrease/)
    end
  end

  describe "limit_method with adaptive registry" do
    before do
      Hanikamu::RateLimit.register_adaptive_limit(
        :adaptive_api,
        initial_rate: 3, interval: 0.5,
        min_rate: 1, max_rate: 20,
        increase_by: 1, decrease_factor: 0.5,
        probe_window: 0.1, cooldown_after_decrease: 0.1,
        error_classes: [TestApiError],
        max_wait_time: 0.3
      )
    end

    let(:klass) do
      Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "AdaptiveTestService"

        attr_reader :call_count

        limit_method :call_api, registry: :adaptive_api

        def initialize
          @call_count = 0
          @should_fail = false
        end

        def fail_next!
          @should_fail = true
        end

        def call_api
          @call_count += 1
          if @should_fail
            @should_fail = false
            raise TestApiError, "429 Too Many Requests"
          end
          "ok"
        end
      end
    end

    it "allows calls up to the initial rate" do
      instance = klass.new
      3.times { expect(instance.call_api).to eq("ok") }
    end

    it "rate-limits when initial rate is exceeded" do
      instance = klass.new
      3.times { instance.call_api }

      expect { instance.call_api }.to raise_error(Hanikamu::RateLimit::RateLimitError)
    end

    it "records success via AdaptiveState" do
      adaptive_state = Hanikamu::RateLimit.fetch_adaptive_state(:adaptive_api)
      expect(adaptive_state).to receive(:record_success!).at_least(:once)

      instance = klass.new
      instance.call_api
    end

    it "decreases rate on error_classes exception" do
      adaptive_state = Hanikamu::RateLimit.fetch_adaptive_state(:adaptive_api)

      instance = klass.new
      instance.fail_next!

      expect { instance.call_api }.to raise_error(TestApiError)

      # After decrease: ceil(initial_rate * 0.5) = ceil(3 * 0.5) = 2
      # (The decrease Lua uses whatever is stored or initial_rate)
      stored = redis.get(adaptive_state.rate_key)
      expect(stored).not_to be_nil
      expect(stored.to_i).to be <= 3
    end

    it "re-raises the original error after decreasing" do
      instance = klass.new
      instance.fail_next!

      expect { instance.call_api }.to raise_error(TestApiError, "429 Too Many Requests")
    end

    it "passes non-error_classes exceptions through without decreasing" do
      adaptive_state = Hanikamu::RateLimit.fetch_adaptive_state(:adaptive_api)
      expect(adaptive_state).not_to receive(:decrease_rate!)

      broken_klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "BrokenService"
        limit_method :call_api, registry: :adaptive_api
        def call_api = raise("unexpected")
      end

      expect { broken_klass.new.call_api }.to raise_error(RuntimeError, "unexpected")
    end

    it "provides a reset method that clears both queue and adaptive state" do
      instance = klass.new
      3.times { instance.call_api }

      expect { instance.call_api }.to raise_error(Hanikamu::RateLimit::RateLimitError)

      klass.reset_call_api_limit!

      # After reset, should be able to call again
      expect(instance.call_api).to eq("ok")
    end
  end

  describe "limit_method with adaptive registry and empty error_classes" do
    before do
      Hanikamu::RateLimit.register_adaptive_limit(
        :simple_adaptive,
        initial_rate: 5, interval: 0.5,
        error_classes: [],
        max_wait_time: 0.3
      )
    end

    it "works as a rate limiter without error handling" do
      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "SimpleAdaptiveService"
        limit_method :execute, registry: :simple_adaptive
        def execute = "done"
      end

      5.times { expect(klass.new.execute).to eq("done") }
      expect { klass.new.execute }.to raise_error(Hanikamu::RateLimit::RateLimitError)
    end
  end

  describe "limit_method with header_parser" do
    before do
      Hanikamu::RateLimit.register_adaptive_limit(
        :parsed_api,
        initial_rate: 5, interval: 1,
        error_classes: [TestApiError],
        header_parser: ->(_error) { { remaining: 2, reset: 5 } },
        max_wait_time: 0.3
      )
    end

    it "feeds parsed headers into register_temporary_limit" do
      expect(Hanikamu::RateLimit).to receive(:register_temporary_limit)
        .with(:parsed_api, remaining: 2, reset: 5)

      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "ParsedApiService"
        limit_method :call_api, registry: :parsed_api
        def call_api = raise(TestApiError, "429")
      end

      expect { klass.new.call_api }.to raise_error(TestApiError)
    end
  end

  describe "fetch_adaptive_state" do
    it "raises for non-adaptive limits" do
      Hanikamu::RateLimit.register_limit(:fixed, rate: 10, interval: 1)

      expect do
        Hanikamu::RateLimit.fetch_adaptive_state(:fixed)
      end.to raise_error(ArgumentError, /not an adaptive limit/)
    end

    it "caches the AdaptiveState instance" do
      Hanikamu::RateLimit.register_adaptive_limit(:cached, initial_rate: 5, interval: 1)

      state1 = Hanikamu::RateLimit.fetch_adaptive_state(:cached)
      state2 = Hanikamu::RateLimit.fetch_adaptive_state(:cached)
      expect(state1).to be(state2)
    end
  end

  describe "reset_limit! for adaptive limits" do
    it "clears both the queue key and adaptive state" do
      Hanikamu::RateLimit.register_adaptive_limit(
        :resettable,
        initial_rate: 5, interval: 1,
        error_classes: [TestApiError]
      )

      state = Hanikamu::RateLimit.fetch_adaptive_state(:resettable)
      redis.set(state.rate_key, 25)

      Hanikamu::RateLimit.reset_limit!(:resettable)

      expect(redis.get(state.rate_key)).to be_nil
    end
  end

  describe "response_parser" do
    before do
      Hanikamu::RateLimit.register_adaptive_limit(
        :resp_parsed_api,
        initial_rate: 5, interval: 1,
        response_parser: lambda { |result|
          next unless result.is_a?(Hash) && result[:headers]

          { remaining: result[:headers][:x_ratelimit_remaining],
            reset: result[:headers][:x_ratelimit_reset] }
        },
        max_wait_time: 0.3
      )
    end

    it "feeds successful response data into register_temporary_limit" do
      expect(Hanikamu::RateLimit).to receive(:register_temporary_limit)
        .with(:resp_parsed_api, remaining: 8, reset: 30, reset_kind: :seconds)

      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "RespParsedService"
        limit_method :call_api, registry: :resp_parsed_api

        def call_api
          { body: "ok", headers: { x_ratelimit_remaining: 8, x_ratelimit_reset: 30 } }
        end
      end

      klass.new.call_api
    end

    it "does nothing when response_parser returns nil" do
      expect(Hanikamu::RateLimit).not_to receive(:register_temporary_limit)

      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "RespNilService"
        limit_method :call_api, registry: :resp_parsed_api
        def call_api = "plain string"
      end

      klass.new.call_api
    end
  end

  describe "report_rate_limit_headers instance helper" do
    before do
      Hanikamu::RateLimit.register_adaptive_limit(
        :manual_api,
        initial_rate: 5, interval: 1,
        max_wait_time: 0.3
      )
    end

    it "is available as an instance method on adaptive classes" do
      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "ManualReportService"
        limit_method :call_api, registry: :manual_api
        def call_api = "ok"
      end

      expect(klass.new).to respond_to(:report_rate_limit_headers)
    end

    it "delegates to register_temporary_limit" do
      expect(Hanikamu::RateLimit).to receive(:register_temporary_limit)
        .with(:manual_api, remaining: 3, reset: 10, reset_kind: :seconds)

      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "ManualReportService2"
        limit_method :call_api, registry: :manual_api

        def call_api
          report_rate_limit_headers(:manual_api, remaining: 3, reset: 10)
          "ok"
        end
      end

      klass.new.call_api
    end

    it "accepts reset_kind: option" do
      expect(Hanikamu::RateLimit).to receive(:register_temporary_limit)
        .with(:manual_api, remaining: 5, reset: 1_740_000_000, reset_kind: :unix)

      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "ManualReportService3"
        limit_method :call_api, registry: :manual_api

        def call_api
          report_rate_limit_headers(:manual_api, remaining: 5, reset: 1_740_000_000, reset_kind: :unix)
          "ok"
        end
      end

      klass.new.call_api
    end
  end
end
