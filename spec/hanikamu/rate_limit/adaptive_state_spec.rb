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
    redis.del(state.rate_key, state.success_count_key,
              state.error_ceiling_key, state.ceiling_hits_key,
              state.ceiling_confidence_key, state.last_probe_at_key, sw_key)
    # Attach a sliding window so utilization can be measured.
    state.attach_sliding_window(sw_key, 1.0)
  end

  after do
    redis.del(state.rate_key, state.success_count_key,
              state.error_ceiling_key, state.ceiling_hits_key,
              state.ceiling_confidence_key, state.last_probe_at_key, sw_key)
  end

  # Populates the sliding window sorted set so utilization = count / rate.
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
      fresh = described_class.new(name, config)
      expect(fresh.current_rate).to eq(25)
    end

    it "caches the rate locally for RATE_CACHE_TTL" do
      expect(state.current_rate).to eq(10)
      redis.set(state.rate_key, 42)
      expect(state.current_rate).to eq(10)
    end
  end

  describe "#record_success!" do
    it "initialises rate and success count on first call" do
      result = state.record_success!
      expect(result).to eq(0)
      expect(redis.get(state.rate_key).to_i).to eq(10)
      expect(redis.get(state.success_count_key).to_i).to eq(0)
    end

    it "does not increase before N successes at current rate" do
      redis.set(state.rate_key, 10)
      redis.set(state.success_count_key, 0)
      fill_sliding_window(10)

      # 5 successes, need 10
      5.times { state.record_success! }
      expect(redis.get(state.rate_key).to_i).to eq(10)
    end

    it "does not increase when utilization is too low" do
      redis.set(state.rate_key, 10)
      redis.set(state.success_count_key, 9) # one more would trigger probe
      fill_sliding_window(3) # 30% utilization, threshold is 70%

      result = state.record_success!
      expect(result).to eq(0)
      expect(redis.get(state.rate_key).to_i).to eq(10)
    end

    context "when N successes accumulated and utilization is high" do
      before do
        redis.set(state.rate_key, 10)
        redis.set(state.success_count_key, 9) # need 10 for rate=10
        fill_sliding_window(8) # 80% utilization
      end

      it "increases the rate by +1" do
        result = state.record_success!
        expect(result).to eq(11)
        expect(redis.get(state.rate_key).to_i).to eq(11)
      end

      it "resets the success counter after probing" do
        state.record_success!
        expect(redis.get(state.success_count_key).to_i).to eq(0)
      end

      it "respects max_rate ceiling" do
        redis.set(state.rate_key, 50)
        redis.set(state.success_count_key, 50)
        fill_sliding_window(45)
        result = state.record_success!
        expect(result).to eq(0) # already at max
      end
    end

    context "with no max_rate" do
      let(:config) { super().merge(max_rate: nil) }

      it "allows rate to grow unbounded" do
        redis.set(state.rate_key, 1000)
        redis.set(state.success_count_key, 999)
        fill_sliding_window(900)

        result = state.record_success!
        expect(result).to eq(1001)
      end
    end

    context "with error ceiling confidence scoring" do
      before do
        redis.set(state.rate_key, 39)
        redis.set(state.success_count_key, 38) # one more triggers probe
        redis.set(state.error_ceiling_key, 40)
        redis.set(state.ceiling_hits_key, 1)
      end

      it "blocks increase past ceiling when utilization is below dynamic threshold" do
        # rate=39, probe to 40 = ceiling
        # dynamic = 0.9 + (1 * 0.02) = 0.92
        fill_sliding_window(34) # 34/39 ≈ 0.87, below 0.92
        result = state.record_success!
        expect(result).to eq(0)
      end

      it "allows increase past ceiling when utilization exceeds dynamic threshold" do
        fill_sliding_window(37) # 37/39 ≈ 0.95, above 0.92
        result = state.record_success!
        expect(result).to eq(40)
      end

      it "becomes harder to break through with more confidence" do
        redis.set(state.ceiling_confidence_key, 5)
        # dynamic = 0.9 + (5 * 0.05) = 1.15 → capped at 1.0
        fill_sliding_window(38) # 38/39 ≈ 0.97, below 1.0
        result = state.record_success!
        expect(result).to eq(0)
      end

      it "allows through at full utilization even with high confidence" do
        redis.set(state.ceiling_hits_key, 1)
        redis.set(state.ceiling_confidence_key, 3)
        # dynamic = 0.9 + (3 * 0.05) = 1.05 → capped at 1.0
        fill_sliding_window(39) # 39/39 = 1.0 which is >= 1.0 threshold
        result = state.record_success!
        expect(result).to eq(40)
      end
    end

    context "with probe cooldown near the ceiling" do
      let(:config) { super().merge(probe_cooldown: 10) }

      before do
        redis.set(state.rate_key, 19)
        redis.set(state.success_count_key, 18) # one more triggers probe
        redis.set(state.error_ceiling_key, 20)
        redis.set(state.ceiling_hits_key, 1)
      end

      it "blocks probing when cooldown has not elapsed" do
        # First probe attempt — should succeed (no previous probe recorded)
        fill_sliding_window(19)
        redis.set(state.last_probe_at_key, Time.now.to_f) # simulate recent probe
        redis.set(state.success_count_key, 18)

        result = state.record_success!
        expect(result).to eq(0)
        expect(redis.get(state.rate_key).to_i).to eq(19)
      end

      it "allows probing when cooldown has elapsed" do
        # Set last_probe_at far in the past
        redis.set(state.last_probe_at_key, Time.now.to_f - 300)
        fill_sliding_window(19) # 19/19 = 1.0 utilization

        result = state.record_success!
        expect(result).to eq(20)
      end

      it "shortens cooldown with ceiling_hits (trust)" do
        redis.set(state.ceiling_hits_key, 5)
        redis.set(state.ceiling_confidence_key, 2)
        # hits incremented to 6 in Lua; cooldown = 10 * (1 + 2) / (1 + 6) ≈ 4.3s
        redis.set(state.last_probe_at_key, Time.now.to_f - 5) # 5s ago, > 4.3s → allowed
        fill_sliding_window(19)

        result = state.record_success!
        expect(result).to eq(20)
      end

      it "lengthens cooldown with ceiling_confidence" do
        redis.set(state.ceiling_confidence_key, 5)
        # hits starts at 1 (before), incremented to 2 in Lua
        # cooldown = 10 * (1 + 5) / (1 + 2) = 20s
        redis.set(state.last_probe_at_key, Time.now.to_f - 15) # 15s < 20s → blocked
        fill_sliding_window(19)

        result = state.record_success!
        expect(result).to eq(0)
      end

      it "caps effective cooldown at max_probe_cooldown" do
        # Override config with a tight max to test the cap
        capped_config = config.merge(max_probe_cooldown: 60)
        capped_state = described_class.new(name, capped_config)
        capped_state.attach_sliding_window(sw_key, 1.0)

        redis.set(state.ceiling_confidence_key, 50)
        # raw = 10 * (1 + 50) = 510, effective = 510 / (1 + 1) = 255, capped at 60
        redis.set(state.last_probe_at_key, Time.now.to_f - 65) # 65s ago, > 60s cap
        fill_sliding_window(19) # 19/19 = 1.0 utilization

        result = capped_state.record_success!
        expect(result).to eq(20)
      end

      it "records last_probe_at when a probe attempt is made" do
        redis.set(state.last_probe_at_key, Time.now.to_f - 300)
        fill_sliding_window(19)

        state.record_success!
        probe_at = redis.get(state.last_probe_at_key).to_f
        expect(probe_at).to be_within(2).of(Time.now.to_f)
      end

      it "resets success counter on cooldown skip" do
        redis.set(state.last_probe_at_key, Time.now.to_f) # just probed
        fill_sliding_window(19)

        state.record_success!
        expect(redis.get(state.success_count_key).to_i).to eq(0)
      end

      it "increments ceiling_hits on each success cycle at the ceiling" do
        # Running at ceiling (rate=20, ceiling=20) with 5 accumulated hits
        redis.set(state.rate_key, 20)
        redis.set(state.success_count_key, 19) # one more triggers success cycle
        redis.set(state.error_ceiling_key, 20)
        redis.set(state.ceiling_hits_key, 5)
        redis.set(state.last_probe_at_key, Time.now.to_f) # cooldown active
        fill_sliding_window(20) # full utilization at rate=20

        # Success cycle fires → ceiling_hits incremented (trust), probe
        # blocked by cooldown so rate stays at 20.
        result = state.record_success!
        expect(result).to eq(0) # blocked by cooldown
        expect(redis.get(state.ceiling_hits_key).to_i).to eq(6)
      end

      it "erodes ceiling_confidence when earned probe is blocked by hard cap" do
        redis.set(state.rate_key, 20)
        redis.set(state.success_count_key, 19)
        redis.set(state.error_ceiling_key, 20)
        redis.set(state.ceiling_hits_key, 5)
        redis.set(state.ceiling_confidence_key, 3)
        redis.set(state.last_probe_at_key, Time.now.to_f - 300) # cooldown elapsed
        fill_sliding_window(20)

        result = state.record_success!
        expect(result).to eq(0) # blocked by hard cap
        expect(redis.get(state.ceiling_confidence_key).to_i).to eq(2) # eroded
        expect(redis.get(state.ceiling_hits_key).to_i).to eq(6) # still incremented
      end

      it "clears ceiling when confidence erodes to zero" do
        redis.set(state.rate_key, 20)
        redis.set(state.success_count_key, 19)
        redis.set(state.error_ceiling_key, 20)
        redis.set(state.ceiling_hits_key, 10)
        redis.set(state.ceiling_confidence_key, 0) # already at zero
        redis.set(state.last_probe_at_key, Time.now.to_f - 300)
        fill_sliding_window(20)

        result = state.record_success!
        # Ceiling cleared — probe goes through
        expect(result).to eq(21)
        expect(redis.get(state.error_ceiling_key)).to be_nil
        expect(redis.get(state.ceiling_hits_key)).to be_nil
        expect(redis.get(state.ceiling_confidence_key)).to be_nil
      end

      it "does not erode when running well below the ceiling" do
        redis.set(state.rate_key, 15)
        redis.set(state.success_count_key, 14)
        redis.set(state.error_ceiling_key, 20)
        redis.set(state.ceiling_hits_key, 3)
        fill_sliding_window(15)

        state.record_success! # probes to 16, below ceiling-1
        expect(redis.get(state.ceiling_hits_key).to_i).to eq(3) # unchanged
      end
    end
  end

  describe "#drop_to_rate!" do
    it "sets the rate to the given ceiling" do
      redis.set(state.rate_key, 30)
      result = state.drop_to_rate!(24)
      expect(result).to eq(24)
      expect(redis.get(state.rate_key).to_i).to eq(24)
    end

    it "floors at min_rate" do
      redis.set(state.rate_key, 10)
      result = state.drop_to_rate!(0)
      expect(result).to eq(1)
    end

    it "caps at max_rate" do
      redis.set(state.rate_key, 50)
      result = state.drop_to_rate!(100)
      expect(result).to be_nil # 50 <= 50 (clamped) — already at target
    end

    it "resets the success counter" do
      redis.set(state.rate_key, 30)
      redis.set(state.success_count_key, 15)
      state.drop_to_rate!(20)
      expect(redis.get(state.success_count_key).to_i).to eq(0)
    end

    it "invalidates the local cache" do
      redis.set(state.rate_key, 30)
      expect(state.current_rate).to eq(30)
      state.drop_to_rate!(20)
      fresh = described_class.new(name, config)
      expect(fresh.current_rate).to eq(20)
    end

    it "records the error ceiling" do
      redis.set(state.rate_key, 30)
      state.drop_to_rate!(24)
      expect(redis.get(state.error_ceiling_key).to_i).to eq(24)
    end

    it "resets ceiling_hits to 0 on first drop (new zone)" do
      redis.set(state.rate_key, 30)
      state.drop_to_rate!(24)
      expect(redis.get(state.ceiling_hits_key).to_i).to eq(0)
    end

    it "preserves ceiling_hits when dropping in the same zone (within 20%)" do
      redis.set(state.rate_key, 30)
      state.drop_to_rate!(24) # first ceiling
      redis.set(state.ceiling_hits_key, 5) # simulate trust built by Lua
      redis.set(state.rate_key, 26)
      state.drop_to_rate!(25) # 25 within 20% of 24 — same zone
      expect(redis.get(state.ceiling_hits_key).to_i).to eq(5) # preserved
    end

    it "still drops for nearby 429s so the rate converges to the real limit" do
      redis.set(state.rate_key, 25)
      state.drop_to_rate!(20) # first discovery, sets ceiling=20
      redis.set(state.rate_key, 20)
      result = state.drop_to_rate!(19) # 19 is within 20% of 20
      expect(result).to eq(19)
      expect(redis.get(state.rate_key).to_i).to eq(19)
    end

    it "does not change ceiling_hits while stepping downward in the same zone" do
      redis.set(state.rate_key, 30)
      state.drop_to_rate!(24)
      expect(redis.get(state.ceiling_hits_key).to_i).to eq(0)

      redis.set(state.rate_key, 24)
      state.drop_to_rate!(23)
      expect(redis.get(state.ceiling_hits_key).to_i).to eq(0)

      redis.set(state.rate_key, 23)
      state.drop_to_rate!(22)
      expect(redis.get(state.ceiling_hits_key).to_i).to eq(0)
    end

    it "skips the drop when rate is already at or below the target" do
      redis.set(state.rate_key, 20)
      result = state.drop_to_rate!(25)
      expect(result).to be_nil
      expect(redis.get(state.rate_key).to_i).to eq(20) # unchanged
    end

    it "preserves ceiling_hits on idempotent (skipped) drops" do
      redis.set(state.rate_key, 30)
      state.drop_to_rate!(19) # first drop → ceiling=19, hits=0
      redis.set(state.ceiling_hits_key, 3) # simulate trust built by Lua

      # Rate is now 19, drop to 19 is idempotent (19 <= 19)
      result = state.drop_to_rate!(19)
      expect(result).to be_nil # rate unchanged
      expect(redis.get(state.rate_key).to_i).to eq(19)
      expect(redis.get(state.ceiling_hits_key).to_i).to eq(3) # preserved
    end

    it "preserves ceiling_hits across probe-then-drop cycles in the same zone" do
      redis.set(state.rate_key, 25)
      state.drop_to_rate!(19) # first drop → ceiling=19, hits=0
      redis.set(state.ceiling_hits_key, 4) # simulate trust built by Lua

      # Simulate probing back to 20, then getting a 429 → drop to 19 again
      redis.set(state.rate_key, 20)
      state.drop_to_rate!(19) # same zone → hits preserved
      expect(redis.get(state.ceiling_hits_key).to_i).to eq(4)

      # Probe to 20 again, another 429 — trust not wiped
      redis.set(state.rate_key, 20)
      state.drop_to_rate!(19)
      expect(redis.get(state.ceiling_hits_key).to_i).to eq(4)
    end

    it "resets ceiling_hits when dropping to a significantly different rate" do
      redis.set(state.rate_key, 30)
      state.drop_to_rate!(24)
      redis.set(state.ceiling_hits_key, 5) # simulate trust built by Lua
      redis.set(state.rate_key, 45)
      state.drop_to_rate!(40) # 40 vs 24 = 67% difference → new zone
      expect(redis.get(state.ceiling_hits_key).to_i).to eq(0)
      expect(redis.get(state.error_ceiling_key).to_i).to eq(40)
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
      redis.set(state.success_count_key, 15)
      redis.set(state.error_ceiling_key, 25)
      redis.set(state.ceiling_hits_key, 3)
      redis.set(state.ceiling_confidence_key, 5)
      redis.set(state.last_probe_at_key, Time.now.to_f)
    end

    it "clears rate and success count" do
      state.reset!
      expect(redis.get(state.rate_key)).to be_nil
      expect(redis.get(state.success_count_key)).to be_nil
    end

    it "clears ceiling state" do
      state.reset!
      expect(redis.get(state.error_ceiling_key)).to be_nil
      expect(redis.get(state.ceiling_hits_key)).to be_nil
      expect(redis.get(state.ceiling_confidence_key)).to be_nil
    end

    it "clears last_probe_at" do
      state.reset!
      expect(redis.get(state.last_probe_at_key)).to be_nil
    end

    it "reverts current_rate to initial_rate" do
      state.reset!
      fresh = described_class.new(name, config)
      expect(fresh.current_rate).to eq(10)
    end
  end

  describe "#state" do
    it "returns rate and success count" do
      redis.set(state.rate_key, 15)
      redis.set(state.success_count_key, 7)

      snapshot = state.state
      expect(snapshot[:current_rate]).to eq(15)
      expect(snapshot[:consecutive_successes]).to eq(7)
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

    it "returns last_probe_at" do
      redis.set(state.rate_key, 15)
      now = Time.now.to_f
      redis.set(state.last_probe_at_key, now)

      snapshot = state.state
      expect(snapshot[:last_probe_at]).to be_within(0.01).of(now)
    end

    it "defaults ceiling_hits and ceiling_confidence to 0 when not set" do
      redis.set(state.rate_key, 15)
      snapshot = state.state
      expect(snapshot[:ceiling_hits]).to eq(0)
      expect(snapshot[:ceiling_confidence]).to eq(0)
    end

    it "includes effective_cooldown and cooldown_remaining when near ceiling" do
      redis.set(state.rate_key, 19)
      redis.set(state.error_ceiling_key, 20)
      redis.set(state.ceiling_hits_key, 1)
      redis.set(state.ceiling_confidence_key, 2)
      redis.set(state.last_probe_at_key, Time.now.to_f - 10)

      snapshot = state.state
      # default probe_cooldown absent → BASE_PROBE_COOLDOWN = 30
      # cooldown = 30 * (1 + 2) / (1 + 1) = 45
      expect(snapshot[:effective_cooldown]).to eq(45)
      expect(snapshot[:cooldown_remaining]).to be_within(2).of(35)
    end

    it "returns nil cooldown fields when rate is not near the ceiling" do
      redis.set(state.rate_key, 10)
      redis.set(state.error_ceiling_key, 20) # current + 1 = 11 < 20

      snapshot = state.state
      expect(snapshot[:effective_cooldown]).to be_nil
      expect(snapshot[:cooldown_remaining]).to be_nil
    end

    it "caps effective_cooldown at max_probe_cooldown" do
      capped_config = config.merge(probe_cooldown: 30, max_probe_cooldown: 60)
      capped_state = described_class.new(name, capped_config)

      redis.set(capped_state.rate_key, 19)
      redis.set(capped_state.error_ceiling_key, 20)
      redis.set(capped_state.ceiling_hits_key, 1)
      redis.set(capped_state.ceiling_confidence_key, 10)

      snapshot = capped_state.state
      # raw = 30 * (1 + 10) / (1 + 1) = 165, capped at 60
      expect(snapshot[:effective_cooldown]).to eq(60)
    end
  end
end
