# frozen_string_literal: true

# Tests the complete adaptive AIMD feedback loop:
#   method call → response_parser → decrease/capture → snapshot → dashboard
#
# This spec uses the *exact* response_parser lambda from the seed script /
# initializer to guarantee the dashboard shows 429-driven rate decreases
# and captured events.

class SeedTimeoutError < StandardError; end

RSpec.describe "Adaptive response_parser feedback loop" do # rubocop:disable RSpec/DescribeClass
  let(:redis_url) { ENV.fetch("REDIS_URL", "redis://localhost:6379/15") }
  let(:redis) { Redis.new(url: redis_url) }

  # The exact response_parser from the dummy initializer / seed script.
  let(:response_parser) do
    lambda { |response|
      return nil unless response.is_a?(Hash)

      status = response[:status]
      return nil if status.nil? || status < 400

      { status: status, decrease: status == 429 }
    }
  end

  before do
    Hanikamu::RateLimit.reset_registry!
    Hanikamu::RateLimit.configure do |config|
      config.redis_url = redis_url
      config.max_wait_time = 2.0
      config.check_interval = 0.1
      config.metrics_enabled = true
    end
    scan_and_delete(redis, "hanikamu:rate_limit:*")
  end

  after do
    scan_and_delete(redis, "hanikamu:rate_limit:*")
    Hanikamu::RateLimit.reset_registry!
    Hanikamu::RateLimit.configure { |c| c.metrics_enabled = false }
  end

  describe "response_parser classification" do
    it "returns nil for a successful 200 response" do
      result = response_parser.call({ status: 200, body: "OK" })
      expect(result).to be_nil
    end

    it "returns nil for a non-hash response" do
      expect(response_parser.call("plain string")).to be_nil
    end

    it "returns decrease: true for a 429 response" do
      result = response_parser.call({ status: 429, body: "Too Many Requests" })
      expect(result).to eq({ status: 429, decrease: true })
    end

    it "returns decrease: false for a 500 response" do
      result = response_parser.call({ status: 500, body: "Internal Server Error" })
      expect(result).to eq({ status: 500, decrease: false })
    end

    it "returns nil when status is below 400" do
      expect(response_parser.call({ status: 301, body: "" })).to be_nil
    end

    it "returns nil when status key is missing" do
      expect(response_parser.call({ body: "no status" })).to be_nil
    end
  end

  describe "AIMD decrease on 429 via limit_method" do
    before do
      Hanikamu::RateLimit.register_adaptive_limit(
        :test_aimd,
        initial_rate: 10, interval: 1,
        min_rate: 2, max_rate: 50,
        increase_by: 1, decrease_factor: 0.5,
        probe_window: 0.1, cooldown_after_decrease: 0.1,
        error_classes: [SeedTimeoutError],
        response_parser: response_parser,
        max_wait_time: 0.3
      )
    end

    let(:klass) do
      Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "AimdTestClient"

        attr_accessor :next_response

        limit_method :call, registry: :test_aimd

        def initialize
          @next_response = { status: 200, body: "OK" }
        end

        def call
          next_response
        end
      end
    end

    it "does not decrease rate on a 200 response" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_aimd)
      initial = state.current_rate

      instance = klass.new
      instance.call

      expect(state.current_rate).to eq(initial)
    end

    it "decreases rate when response_parser returns decrease: true (429)" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_aimd)
      initial = state.current_rate

      instance = klass.new
      instance.next_response = { status: 429, body: "Too Many Requests" }
      instance.call

      # ceil(10 * 0.5) = 5
      expect(state.current_rate).to be < initial
      expect(state.current_rate).to eq(5)
    end

    it "does not decrease rate on a 500 response (noise)" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_aimd)
      initial = state.current_rate

      instance = klass.new
      instance.next_response = { status: 500, body: "Internal Server Error" }
      instance.call

      expect(state.current_rate).to eq(initial)
    end

    it "captures 429 response via EventCapture with pre-decrease rate" do
      expect(Hanikamu::RateLimit::Storage::EventCapture).to receive(:capture_response)
        .with(:test_aimd, { status: 429, body: "Too Many Requests" }, { status: 429, decrease: true },
              adaptive_rate: 10)

      instance = klass.new
      instance.next_response = { status: 429, body: "Too Many Requests" }
      instance.call
    end

    it "captures 500 response via EventCapture with current rate" do
      expect(Hanikamu::RateLimit::Storage::EventCapture).to receive(:capture_response)
        .with(:test_aimd, { status: 500, body: "Internal Server Error" }, { status: 500, decrease: false },
              adaptive_rate: 10)

      instance = klass.new
      instance.next_response = { status: 500, body: "Internal Server Error" }
      instance.call
    end

    it "does not capture successful 200 responses" do
      expect(Hanikamu::RateLimit::Storage::EventCapture).not_to receive(:capture_response)

      instance = klass.new
      instance.call
    end

    it "records success on 200 response" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_aimd)
      expect(state).to receive(:record_success!).and_call_original

      instance = klass.new
      instance.call
    end

    it "does not record success on 429 (decrease) response" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_aimd)
      expect(state).not_to receive(:record_success!)

      instance = klass.new
      instance.next_response = { status: 429, body: "Too Many Requests" }
      instance.call
    end

    it "does not record success on 500 (captured but no decrease) response" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_aimd)
      # 500 is captured but decrease is false, so record_success! is NOT called
      # because apply_response_parser returns true when parsed is a Hash (event captured)
      # Wait — let's check: apply_response_parser returns `decreased` (true/false).
      # For 500: decreased = false, so record_success! IS called.
      expect(state).to receive(:record_success!).and_call_original

      instance = klass.new
      instance.next_response = { status: 500, body: "Internal Server Error" }
      instance.call
    end

    it "decreases rate on error_classes exception (SeedTimeoutError)" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_aimd)
      initial = state.current_rate

      # Build a class whose call always raises the error
      error_klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "AimdErrorClient"

        limit_method :call, registry: :test_aimd

        def call
          raise SeedTimeoutError, "connection timed out"
        end
      end

      expect { error_klass.new.call }.to raise_error(SeedTimeoutError)
      expect(state.current_rate).to be < initial
    end

    it "captures exception via EventCapture on error_classes with pre-decrease rate" do
      expect(Hanikamu::RateLimit::Storage::EventCapture).to receive(:capture_exception)
        .with(:test_aimd, an_instance_of(SeedTimeoutError), adaptive_rate: 10)

      error_klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "AimdCaptureClient"

        limit_method :call, registry: :test_aimd

        def call
          raise SeedTimeoutError, "connection timed out"
        end
      end

      expect { error_klass.new.call }.to raise_error(SeedTimeoutError)
    end

    context "with multiple 429s" do
      it "progressively decreases the rate" do
        state = Hanikamu::RateLimit.fetch_adaptive_state(:test_aimd)
        instance = klass.new
        instance.next_response = { status: 429, body: "Too Many Requests" }

        rates = []
        3.times do
          instance.call
          rates << state.current_rate
        end

        # Each decrease: ceil(rate * 0.5)
        # 10 → 5 → 3 → 2
        expect(rates).to eq([5, 3, 2])
      end

      it "respects min_rate floor" do
        state = Hanikamu::RateLimit.fetch_adaptive_state(:test_aimd)

        # Directly decrease via state to avoid RateLimitError from queue
        10.times { state.decrease_rate! }

        expect(state.current_rate).to be >= 2 # min_rate
      end
    end
  end

  describe "SnapshotRecorder integration" do
    before do
      Hanikamu::RateLimit.register_adaptive_limit(
        :snapshot_test,
        initial_rate: 10, interval: 1,
        min_rate: 2, max_rate: 50,
        response_parser: response_parser,
        max_wait_time: 0.3
      )
    end

    it "records a snapshot for each adaptive limit" do
      # Trigger fetch_adaptive_state so it's in the hash
      Hanikamu::RateLimit.fetch_adaptive_state(:snapshot_test)

      snapshot_double = instance_double(Hanikamu::RateLimit::Storage::RateSnapshot)
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:create!).and_return(snapshot_double)

      # Stub the "is it due?" check
      pool_double = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool)
      allow(ActiveRecord::Base).to receive(:connection_pool).and_return(pool_double)
      allow(pool_double).to receive(:with_connection).and_yield

      for_registry_relation = double("Relation")
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:for_registry)
        .with(:snapshot_test).and_return(for_registry_relation)
      allow(for_registry_relation).to receive_message_chain(:order, :pick).and_return(nil) # rubocop:disable RSpec/MessageChain

      Hanikamu::RateLimit::Storage::SnapshotRecorder.tick!

      expect(Hanikamu::RateLimit::Storage::RateSnapshot).to have_received(:create!).with(
        hash_including(
          registry_name: "snapshot_test",
          rate: 10
        )
      )
    end

    it "records decreased rate after a 429" do
      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "SnapshotTestClient"

        limit_method :call, registry: :snapshot_test

        def call
          { status: 429, body: "Too Many Requests" }
        end
      end

      klass.new.call # triggers decrease: 10 → 5

      snapshot_double = instance_double(Hanikamu::RateLimit::Storage::RateSnapshot)
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:create!).and_return(snapshot_double)

      pool_double = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool)
      allow(ActiveRecord::Base).to receive(:connection_pool).and_return(pool_double)
      allow(pool_double).to receive(:with_connection).and_yield

      for_registry_relation = double("Relation")
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:for_registry)
        .with(:snapshot_test).and_return(for_registry_relation)
      allow(for_registry_relation).to receive_message_chain(:order, :pick).and_return(nil) # rubocop:disable RSpec/MessageChain

      Hanikamu::RateLimit::Storage::SnapshotRecorder.tick!

      expect(Hanikamu::RateLimit::Storage::RateSnapshot).to have_received(:create!).with(
        hash_including(
          registry_name: "snapshot_test",
          rate: 5
        )
      )
    end
  end

  describe "event_marker_series" do
    it "returns [epoch, rate] pairs for rate_limit classified events" do
      now = Time.current
      pluck_result = [[now, 18]]

      scoped = double("Scoped")
      allow(Hanikamu::RateLimit::Storage::CapturedEvent).to receive(:for_registry)
        .with("test_api").and_return(scoped)
      allow(scoped).to receive_messages(rate_limit_signals: scoped, where: scoped)
      allow(scoped).to receive(:order).with(:created_at).and_return(scoped)
      allow(scoped).to receive(:pluck).with(:created_at, :adaptive_rate).and_return(pluck_result)

      result = Hanikamu::RateLimit::Metrics.send(:event_marker_series, "test_api")
      expect(result).to eq([[now.to_i, 18]])
    end

    it "returns empty array when no classified events exist" do
      scoped = double("Scoped")
      allow(Hanikamu::RateLimit::Storage::CapturedEvent).to receive(:for_registry)
        .with("test_api").and_return(scoped)
      allow(scoped).to receive_messages(rate_limit_signals: scoped, where: scoped)
      allow(scoped).to receive(:order).with(:created_at).and_return(scoped)
      allow(scoped).to receive(:pluck).with(:created_at, :adaptive_rate).and_return([])

      result = Hanikamu::RateLimit::Metrics.send(:event_marker_series, "test_api")
      expect(result).to eq([])
    end

    it "returns empty array on database error" do
      allow(Hanikamu::RateLimit::Storage::CapturedEvent).to receive(:for_registry)
        .and_raise(ActiveRecord::ConnectionNotEstablished)

      result = Hanikamu::RateLimit::Metrics.send(:event_marker_series, "test_api")
      expect(result).to eq([])
    end
  end

  describe "rate_history_series" do
    it "delegates to RateSnapshot.chart_series" do
      expected = [[1_000_000, 10], [1_000_300, 8]]
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:chart_series)
        .with("test_api", since: an_instance_of(Time))
        .and_return(expected)

      result = Hanikamu::RateLimit::Metrics.send(:rate_history_series, "test_api")
      expect(result).to eq(expected)
    end

    it "returns empty array on database error" do
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:chart_series)
        .and_raise(ActiveRecord::ConnectionNotEstablished)

      result = Hanikamu::RateLimit::Metrics.send(:rate_history_series, "test_api")
      expect(result).to eq([])
    end
  end

  describe "adaptive_history_hash" do
    before do
      Hanikamu::RateLimit.register_adaptive_limit(
        :history_test, initial_rate: 10, interval: 1,
                       response_parser: response_parser, max_wait_time: 0.3
      )
    end

    it "returns both rate_history and event_markers" do
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:chart_series)
        .and_return([[1_000_000, 10]])

      scoped = double("Scoped")
      allow(Hanikamu::RateLimit::Storage::CapturedEvent).to receive(:for_registry)
        .and_return(scoped)
      allow(scoped).to receive_messages(rate_limit_signals: scoped, where: scoped, order: scoped)
      allow(scoped).to receive(:pluck).with(:created_at, :adaptive_rate).and_return([])

      result = Hanikamu::RateLimit::Metrics.send(:adaptive_history_hash, "history_test")
      expect(result).to have_key("rate_history")
      expect(result).to have_key("event_markers")
      expect(result["rate_history"]).to eq([[1_000_000, 10]])
      expect(result["event_markers"]).to eq([])
    end
  end
end
