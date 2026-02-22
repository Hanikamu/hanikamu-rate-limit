# frozen_string_literal: true

RSpec.describe Hanikamu::RateLimit::AdaptiveState do
  subject(:state) { described_class.new(name, config) }

  let(:redis_url) { ENV.fetch("REDIS_URL", "redis://localhost:6379/15") }
  let(:redis) { Redis.new(url: redis_url) }
  let(:name) { :test_adaptive }
  let(:config) do
    {
      initial_rate: 10,
      min_rate: 1,
      max_rate: 50,
      increase_by: 2,
      decrease_factor: 0.5,
      probe_window: 60,
      cooldown_after_decrease: 30,
      utilization_threshold: 0.7,
      ceiling_threshold: 0.9
    }
  end

  # A helper sorted-set key used to simulate the sliding window for utilization.
  let(:sw_key) { "hanikamu:rate_limit:rate_queue:test_adaptive_sw:1.0" }

  before do
    Hanikamu::RateLimit.configure do |c|
      c.redis_url = redis_url
    end
    redis.del(state.rate_key, state.cooldown_key, state.probe_key,
              state.error_ceiling_key, state.ceiling_hits_key,
              state.ceiling_confidence_key, sw_key)
    # Attach a sliding window so utilization can be measured.
    state.attach_sliding_window(sw_key, 1.0)
  end

  after do
    redis.del(state.rate_key, state.cooldown_key, state.probe_key,
              state.error_ceiling_key, state.ceiling_hits_key,
              state.ceiling_confidence_key, sw_key)
  end

  # Populates the sliding window sorted set so utilization = count / rate.
  # All entries are placed within the last 0.5s so they survive the 1s window cleanup.
  def fill_sliding_window(count, now: Time.now.to_f)
    count.times do |i|
      redis.zadd(sw_key, now - (i * 0.0005), "#{now}-#{i}")
    end
  end

  describe "#current_rate" do
    it "returns initial_rate when Redis has no stored value" do
      expect(state.current_rate).to eq(10)
    end

    it "returns the stored rate from Redis" do
      redis.set(state.rate_key, 25)
      # Invalidate local cache by creating a fresh instance
      fresh = described_class.new(name, config)
      expect(fresh.current_rate).to eq(25)
    end

    it "caches the rate locally for RATE_CACHE_TTL" do
      expect(state.current_rate).to eq(10)

      # Change rate in Redis behind the cache's back
      redis.set(state.rate_key, 42)

      # Still returns cached value
      expect(state.current_rate).to eq(10)
    end
  end

  describe "#record_success!" do
    it "initialises rate and probe timestamp on first call" do
      result = state.record_success!
      expect(result).to eq(0)
      expect(redis.get(state.rate_key).to_i).to eq(10)
      expect(redis.get(state.probe_key)).not_to be_nil
    end

    it "does not increase during cooldown" do
      # Set rate and put us in cooldown
      redis.set(state.rate_key, 10)
      redis.set(state.cooldown_key, Time.now.to_f.to_s)
      redis.set(state.probe_key, "0") # probe_window expired
      fill_sliding_window(10)

      result = state.record_success!
      expect(result).to eq(0)
      expect(redis.get(state.rate_key).to_i).to eq(10)
    end

    it "does not increase when probe window has not elapsed" do
      redis.set(state.rate_key, 10)
      redis.set(state.probe_key, Time.now.to_f.to_s)
      fill_sliding_window(10)

      result = state.record_success!
      expect(result).to eq(0)
      expect(redis.get(state.rate_key).to_i).to eq(10)
    end

    it "does not increase when utilization is too low" do
      redis.set(state.rate_key, 10)
      redis.set(state.probe_key, (Time.now.to_f - 61).to_s)
      # Only 3 of 10 slots used → 30% utilization, threshold is 70%
      fill_sliding_window(3)

      result = state.record_success!
      expect(result).to eq(0)
      expect(redis.get(state.rate_key).to_i).to eq(10)
    end

    context "when probe window has elapsed, no cooldown, and utilization is high" do
      before do
        redis.set(state.rate_key, 10)
        redis.set(state.probe_key, (Time.now.to_f - 61).to_s)
        fill_sliding_window(8) # 80% utilization, above 70% threshold
      end

      it "increases the rate by increase_by" do
        result = state.record_success!
        expect(result).to eq(12)
        expect(redis.get(state.rate_key).to_i).to eq(12)
      end

      it "respects max_rate ceiling" do
        redis.set(state.rate_key, 49)
        fill_sliding_window(45) # keep utilization high for rate=49
        result = state.record_success!
        expect(result).to eq(50)
      end

      it "updates the probe timestamp" do
        old_probe = redis.get(state.probe_key).to_f
        state.record_success!
        new_probe = redis.get(state.probe_key).to_f
        expect(new_probe).to be > old_probe
      end
    end

    context "with no max_rate" do
      let(:config) { super().merge(max_rate: nil) }

      it "allows rate to grow unbounded" do
        redis.set(state.rate_key, 1000)
        redis.set(state.probe_key, (Time.now.to_f - 61).to_s)
        fill_sliding_window(900) # 90% utilization

        result = state.record_success!
        expect(result).to eq(1002)
      end
    end

    context "with error ceiling confidence scoring" do
      before do
        redis.set(state.rate_key, 38)
        redis.set(state.probe_key, (Time.now.to_f - 61).to_s)
        # Set a ceiling at 40 with 1 hit
        redis.set(state.error_ceiling_key, 40)
        redis.set(state.ceiling_hits_key, 1)
      end

      it "blocks increase past ceiling when utilization is below dynamic threshold" do
        # rate=38, increase_by=2 → 40 = ceiling
        # dynamic = 0.9 + (1 * 0.02) = 0.92
        # utilization = 35/38 ≈ 0.92 — right at the boundary
        fill_sliding_window(34) # 34/38 ≈ 0.89, below 0.92
        result = state.record_success!
        expect(result).to eq(0)
      end

      it "allows increase past ceiling when utilization exceeds dynamic threshold" do
        fill_sliding_window(36) # 36/38 ≈ 0.95, above 0.92
        result = state.record_success!
        expect(result).to eq(40)
      end

      it "becomes harder to break through with more hits" do
        redis.set(state.ceiling_hits_key, 5)
        # dynamic = 0.9 + (5 * 0.02) = 1.0 → capped at 1.0
        fill_sliding_window(37) # 37/38 ≈ 0.97, still below 1.0
        result = state.record_success!
        expect(result).to eq(0)
      end

      it "becomes even harder with ceiling confidence from classified events" do
        redis.set(state.ceiling_hits_key, 1)
        redis.set(state.ceiling_confidence_key, 3)
        # dynamic = 0.9 + (1 * 0.02) + (3 * 0.05) = 1.07 → capped at 1.0
        fill_sliding_window(38) # 38/38 = 1.0, but threshold is 1.0 and need < for fail
        result = state.record_success!
        expect(result).to eq(40) # utilization = 1.0 which is >= 1.0 threshold
      end

      it "effectively blocks all increases when confidence is very high" do
        redis.set(state.ceiling_hits_key, 3)
        redis.set(state.ceiling_confidence_key, 5)
        # dynamic = 0.9 + 0.06 + 0.25 = 1.21 → capped at 1.0
        # Utilization can never exceed 1.0, so no increase is possible
        fill_sliding_window(38)
        state.record_success!
        # With threshold at 1.0 and utilization at 1.0, it should still pass (>=)
        # Let's set rate higher so utilization < 1.0
        redis.set(state.rate_key, 40)
        fill_sliding_window(39) # 39/40 = 0.975, below 1.0
        result = state.record_success!
        expect(result).to eq(0)
      end
    end
  end

  describe "#decrease_rate!" do
    it "applies multiplicative decrease" do
      redis.set(state.rate_key, 20)
      result = state.decrease_rate!
      expect(result).to eq(10) # ceil(20 * 0.5)
    end

    it "uses initial_rate when no rate is stored" do
      result = state.decrease_rate!
      expect(result).to eq(5) # ceil(10 * 0.5)
    end

    it "floors at min_rate" do
      redis.set(state.rate_key, 1)
      result = state.decrease_rate!
      expect(result).to eq(1) # max(ceil(1 * 0.5), 1)
    end

    it "sets the cooldown timestamp" do
      redis.set(state.rate_key, 20)
      before = Time.now.to_f
      state.decrease_rate!

      cooldown = redis.get(state.cooldown_key).to_f
      expect(cooldown).to be_within(0.1).of(before)
    end

    it "invalidates the local cache" do
      redis.set(state.rate_key, 20)
      expect(state.current_rate).to eq(20)

      state.decrease_rate!
      fresh = described_class.new(name, config)
      expect(fresh.current_rate).to eq(10)
    end

    it "records the error ceiling at the pre-decrease rate" do
      redis.set(state.rate_key, 20)
      state.decrease_rate!
      expect(redis.get(state.error_ceiling_key).to_i).to eq(20)
    end

    it "sets ceiling_hits to 1 on first decrease" do
      redis.set(state.rate_key, 20)
      state.decrease_rate!
      expect(redis.get(state.ceiling_hits_key).to_i).to eq(1)
    end

    it "increments ceiling_hits when error occurs near the same ceiling (within 20%)" do
      redis.set(state.rate_key, 20)
      state.decrease_rate! # ceiling=20, hits=1

      # Climb back to 19 (within 20% of 20)
      redis.set(state.rate_key, 19)
      state.decrease_rate! # ceiling=19, but 20→19 is within 20%, hits=2

      expect(redis.get(state.ceiling_hits_key).to_i).to eq(2)
    end

    it "resets ceiling_hits when error occurs at a significantly different rate" do
      redis.set(state.rate_key, 20)
      state.decrease_rate! # ceiling=20, hits=1

      # Jump to a very different rate
      redis.set(state.rate_key, 40)
      state.decrease_rate! # 40 vs 20 = 100% difference, resets to 1

      expect(redis.get(state.ceiling_hits_key).to_i).to eq(1)
      expect(redis.get(state.error_ceiling_key).to_i).to eq(40)
    end
  end

  describe "#handle_error" do
    let(:error) { StandardError.new("rate limited") }

    context "when header_parser returns remaining" do
      let(:parser) { ->(_e) { { remaining: 5, reset: 10 } } }

      before do
        Hanikamu::RateLimit.reset_registry!
        Hanikamu::RateLimit.register_adaptive_limit(
          name, initial_rate: 10, interval: 1,
                error_classes: [StandardError]
        )
      end

      it "registers a temporary limit instead of decreasing" do
        expect(Hanikamu::RateLimit).to receive(:register_temporary_limit)
          .with(name, remaining: 5, reset: 10)

        state.handle_error(error, name, parser)
      end
    end

    context "when header_parser is nil" do
      it "calls decrease_rate!" do
        redis.set(state.rate_key, 20)
        state.handle_error(error, name, nil)
        expect(redis.get(state.rate_key).to_i).to eq(10)
      end
    end

    context "when header_parser returns non-hash" do
      let(:parser) { ->(_e) {} }

      it "falls back to decrease_rate!" do
        redis.set(state.rate_key, 20)
        state.handle_error(error, name, parser)
        expect(redis.get(state.rate_key).to_i).to eq(10)
      end
    end
  end

  describe "#handle_response" do
    let(:result) { { body: "ok", headers: { x_ratelimit_remaining: 8, x_ratelimit_reset: 30 } } }

    context "when response_parser returns remaining" do
      let(:parser) do
        lambda { |r|
          { remaining: r[:headers][:x_ratelimit_remaining], reset: r[:headers][:x_ratelimit_reset] }
        }
      end

      before do
        Hanikamu::RateLimit.reset_registry!
        Hanikamu::RateLimit.register_adaptive_limit(name, initial_rate: 10, interval: 1)
      end

      it "registers a temporary limit" do
        expect(Hanikamu::RateLimit).to receive(:register_temporary_limit)
          .with(name, remaining: 8, reset: 30)

        state.handle_response(result, name, parser)
      end
    end

    context "when response_parser is nil" do
      it "does nothing" do
        expect(Hanikamu::RateLimit).not_to receive(:register_temporary_limit)
        state.handle_response(result, name, nil)
      end
    end

    context "when response_parser returns non-hash" do
      let(:parser) { ->(_r) {} }

      it "does nothing" do
        expect(Hanikamu::RateLimit).not_to receive(:register_temporary_limit)
        state.handle_response(result, name, parser)
      end
    end
  end

  describe "#sync_ceiling_confidence!" do
    it "sets the ceiling confidence count in Redis" do
      state.sync_ceiling_confidence!(7)
      expect(redis.get(state.ceiling_confidence_key).to_i).to eq(7)
    end

    it "clamps negative values to 0" do
      state.sync_ceiling_confidence!(-3)
      expect(redis.get(state.ceiling_confidence_key).to_i).to eq(0)
    end

    it "overwrites previous values" do
      state.sync_ceiling_confidence!(5)
      state.sync_ceiling_confidence!(2)
      expect(redis.get(state.ceiling_confidence_key).to_i).to eq(2)
    end
  end

  describe "#reset!" do
    before do
      redis.set(state.rate_key, 25)
      redis.set(state.cooldown_key, Time.now.to_f.to_s)
      redis.set(state.probe_key, Time.now.to_f.to_s)
      redis.set(state.error_ceiling_key, 25)
      redis.set(state.ceiling_hits_key, 3)
      redis.set(state.ceiling_confidence_key, 5)
    end

    it "clears rate and timing state" do
      state.reset!

      expect(redis.get(state.rate_key)).to be_nil
      expect(redis.get(state.cooldown_key)).to be_nil
      expect(redis.get(state.probe_key)).to be_nil
    end

    it "clears ceiling state" do
      state.reset!

      expect(redis.get(state.error_ceiling_key)).to be_nil
      expect(redis.get(state.ceiling_hits_key)).to be_nil
      expect(redis.get(state.ceiling_confidence_key)).to be_nil
    end

    it "reverts current_rate to initial_rate" do
      redis.set(state.rate_key, 25)
      state.reset!
      fresh = described_class.new(name, config)
      expect(fresh.current_rate).to eq(10)
    end
  end

  describe "#state" do
    it "returns rate and timing fields" do
      redis.set(state.rate_key, 15)
      redis.set(state.cooldown_key, "1000.0")
      redis.set(state.probe_key, "2000.0")

      snapshot = state.state
      expect(snapshot[:current_rate]).to eq(15)
      expect(snapshot[:last_decrease_at]).to eq(1000.0)
      expect(snapshot[:last_probe_at]).to eq(2000.0)
      expect(snapshot[:cooldown_active]).to be(false) # ancient timestamp
    end

    it "returns ceiling fields" do
      redis.set(state.rate_key, 15)
      redis.set(state.error_ceiling_key, 20)
      redis.set(state.ceiling_hits_key, 3)
      redis.set(state.ceiling_confidence_key, 2)

      snapshot = state.state
      expect(snapshot[:error_ceiling]).to eq(20)
      expect(snapshot[:ceiling_hits]).to eq(3)
      expect(snapshot[:ceiling_confidence]).to eq(2)
    end

    it "shows cooldown_active when in cooldown" do
      redis.set(state.rate_key, 15)
      redis.set(state.cooldown_key, Time.now.to_f.to_s)

      expect(state.state[:cooldown_active]).to be(true)
    end

    it "defaults ceiling_hits and ceiling_confidence to 0 when not set" do
      redis.set(state.rate_key, 15)
      snapshot = state.state
      expect(snapshot[:ceiling_hits]).to eq(0)
      expect(snapshot[:ceiling_confidence]).to eq(0)
    end
  end
end
