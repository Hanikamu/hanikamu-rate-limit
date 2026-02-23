# frozen_string_literal: true

# Tests the adaptive response_parser capture-only feedback loop:
#   method call → response_parser → capture event → (no rate change)
#
# In the new ceiling-based model, the response_parser is a capture filter:
# it decides what's worth recording, not whether to decrease rate.
# Rate changes only happen when events are classified in the Learning UI.

class SeedTimeoutError < StandardError; end

RSpec.describe "Adaptive response_parser feedback loop" do # rubocop:disable RSpec/DescribeClass
  let(:redis_url) { ENV.fetch("REDIS_URL", "redis://localhost:6379/15") }
  let(:redis) { Redis.new(url: redis_url) }

  # A capture-only response_parser: returns a hash for any >=400 status.
  # No `decrease: true` — just captures the event for the Learning UI.
  let(:response_parser) do
    lambda { |response|
      return nil unless response.is_a?(Hash)

      status = response[:status]
      return nil if status.nil? || status < 400

      { status: status }
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

    it "returns a hash for a 429 response" do
      result = response_parser.call({ status: 429, body: "Too Many Requests" })
      expect(result).to eq({ status: 429 })
    end

    it "returns a hash for a 500 response" do
      result = response_parser.call({ status: 500, body: "Internal Server Error" })
      expect(result).to eq({ status: 500 })
    end

    it "returns nil when status is below 400" do
      expect(response_parser.call({ status: 301, body: "" })).to be_nil
    end

    it "returns nil when status key is missing" do
      expect(response_parser.call({ body: "no status" })).to be_nil
    end
  end

  describe "capture-only on error responses via limit_method" do
    before do
      Hanikamu::RateLimit.register_adaptive_limit(
        :test_capture,
        initial_rate: 10, interval: 1,
        min_rate: 2, max_rate: 50,
        error_classes: [SeedTimeoutError],
        response_parser: response_parser,
        max_wait_time: 0.3
      )
    end

    let(:klass) do
      Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "CaptureTestClient"

        attr_accessor :next_response

        limit_method :call, registry: :test_capture

        def initialize
          @next_response = { status: 200, body: "OK" }
        end

        def call
          next_response
        end
      end
    end

    it "does not change rate on a 200 response" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_capture)
      initial = state.current_rate

      instance = klass.new
      instance.call

      expect(state.current_rate).to eq(initial)
    end

    it "does NOT decrease rate on a 429 response (capture only)" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_capture)
      initial = state.current_rate

      instance = klass.new
      instance.next_response = { status: 429, body: "Too Many Requests" }
      instance.call

      # Rate stays the same — no automatic decrease
      expect(state.current_rate).to eq(initial)
    end

    it "does not change rate on a 500 response" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_capture)
      initial = state.current_rate

      instance = klass.new
      instance.next_response = { status: 500, body: "Internal Server Error" }
      instance.call

      expect(state.current_rate).to eq(initial)
    end

    it "captures 429 response via EventCapture with current rate" do
      expect(Hanikamu::RateLimit::Storage::EventCapture).to receive(:capture_response)
        .with(:test_capture, { status: 429, body: "Too Many Requests" }, { status: 429 },
              adaptive_rate: 10)

      instance = klass.new
      instance.next_response = { status: 429, body: "Too Many Requests" }
      instance.call
    end

    it "captures 500 response via EventCapture with current rate" do
      expect(Hanikamu::RateLimit::Storage::EventCapture).to receive(:capture_response)
        .with(:test_capture, { status: 500, body: "Internal Server Error" }, { status: 500 },
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
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_capture)
      expect(state).to receive(:record_success!).and_call_original

      instance = klass.new
      instance.call
    end

    it "does NOT record success on 429 (captured) response" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_capture)
      expect(state).not_to receive(:record_success!)

      instance = klass.new
      instance.next_response = { status: 429, body: "Too Many Requests" }
      instance.call
    end

    it "does NOT record success on 500 (captured) response" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_capture)
      expect(state).not_to receive(:record_success!)

      instance = klass.new
      instance.next_response = { status: 500, body: "Internal Server Error" }
      instance.call
    end

    it "captures exception via EventCapture on error_classes" do
      expect(Hanikamu::RateLimit::Storage::EventCapture).to receive(:capture_exception)
        .with(:test_capture, an_instance_of(SeedTimeoutError), adaptive_rate: 10)

      error_klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "CaptureErrorClient"

        limit_method :call, registry: :test_capture

        def call
          raise SeedTimeoutError, "connection timed out"
        end
      end

      expect { error_klass.new.call }.to raise_error(SeedTimeoutError)
    end

    it "does NOT decrease rate on error_classes exception (capture only)" do
      state = Hanikamu::RateLimit.fetch_adaptive_state(:test_capture)
      initial = state.current_rate

      error_klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "NoDecreaseErrorClient"

        limit_method :call, registry: :test_capture

        def call
          raise SeedTimeoutError, "connection timed out"
        end
      end

      expect { error_klass.new.call }.to raise_error(SeedTimeoutError)
      expect(state.current_rate).to eq(initial)
    end

    context "with multiple 429 responses" do
      it "rate stays constant (no auto-decrease)" do
        state = Hanikamu::RateLimit.fetch_adaptive_state(:test_capture)
        initial = state.current_rate
        instance = klass.new
        instance.next_response = { status: 429, body: "Too Many Requests" }

        3.times { instance.call }

        expect(state.current_rate).to eq(initial)
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

    it "records unchanged rate after 429 (no auto-decrease)" do
      klass = Class.new do
        extend Hanikamu::RateLimit::Mixin

        def self.name = "SnapshotTestClient"

        limit_method :call, registry: :snapshot_test

        def call
          { status: 429, body: "Too Many Requests" }
        end
      end

      klass.new.call # captures event but rate stays at 10

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
          rate: 10
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
