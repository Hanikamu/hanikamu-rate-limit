# frozen_string_literal: true

RSpec.describe Hanikamu::RateLimit::RateQueue do
  subject do
    described_class.new(
      rate,
      klass_name: klass_name,
      method: method_name,
      interval: interval,
      check_interval: check_interval,
      max_wait_time: max_wait_time,
      &callback
    )
  end

  let(:redis_url) { ENV.fetch("REDIS_URL", "redis://localhost:6379/15") }
  let(:redis) { Redis.new(url: redis_url) }
  let(:rate) { 2 }
  let(:interval) { 0.2 }
  let(:klass_name) { "TestClient" }
  let(:method_name) { "execute" }
  let(:check_interval) { 0.05 }
  let(:max_wait_time) { 1.0 }
  let(:callback) { nil }

  before do
    Hanikamu::RateLimit.configure do |config|
      config.redis_url = redis_url
      config.max_wait_time = 2.0
      config.check_interval = 0.5
    end
    begin
      subject.reset
    rescue Redis::BaseError
      nil
    end
  end

  after do
    Hanikamu::RateLimit.configure do |config|
      config.redis_url = redis_url
      config.max_wait_time = 2.0
      config.check_interval = 0.5
    end
    begin
      subject.reset
    rescue Redis::BaseError
      nil
    end
  end

  describe "#shift" do
    ThreadCoordinator = Struct.new(:queue_one, :queue_two) do
      def duration
        ready, start_signal, times = build_queues
        threads = start_threads(ready, start_signal, times)
        start_time = release_threads(ready, start_signal)
        wait_for_threads(threads)
        finish_time(times) - start_time
      end

      private

      def build_queues
        [Queue.new, Queue.new, Queue.new]
      end

      def start_threads(ready, start_signal, times)
        [queue_one, queue_two].map do |queue|
          Thread.new do
            ready << true
            start_signal.pop
            queue.shift
            times << Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
      end

      def release_threads(ready, start_signal)
        2.times { ready.pop }
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        2.times { start_signal << true }
        start_time
      end

      def wait_for_threads(threads)
        threads.each { |t| t.join(5) }
        raise "Thread did not finish in time" if threads.any?(&:alive?)
      end

      def finish_time(times)
        t1 = times.pop
        t2 = times.pop
        [t1, t2].max
      end
    end

    context "when under rate limit" do
      it "returns immediately without sleeping" do
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        subject.shift
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        expect(elapsed).to be < 0.1
      end

      it "allows multiple requests up to rate limit" do
        rate.times do
          expect { subject.shift }.not_to raise_error
        end
      end
    end

    context "when override_key is not provided" do
      it "uses a single Redis key" do
        expect(subject.send(:redis_keys)).to eq([subject.send(:redis_key)])
      end
    end

    context "when rate limit is reached" do
      before do
        rate.times { subject.shift }
      end

      context "without check_interval or max_wait_time" do
        let(:check_interval) { nil }
        let(:max_wait_time) { nil }

        before do
          Hanikamu::RateLimit.configure do |config|
            config.check_interval = interval * 2
            config.max_wait_time = interval * 5
          end
        end

        it "sleeps for the full calculated time" do
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          subject.shift
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

          expect(elapsed).to be >= (interval - 0.05)
        end
      end

      context "with check_interval" do
        it "retries until a slot opens up" do
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          subject.shift
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

          expect(elapsed).to be >= (interval - 0.02)
          expect(elapsed).to be < (interval + check_interval + 0.1)
        end
      end

      context "with max_wait_time" do
        let(:max_wait_time) { 0.05 }

        it "raises error when max_wait_time is exceeded" do
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          expect do
            subject.shift
          end.to raise_error(Hanikamu::RateLimit::RateLimitError, /Max wait time exceeded/)

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
          expect(elapsed).to be >= max_wait_time
        end

        context "when max_wait_time is long enough" do
          let(:max_wait_time) { 1.0 }

          it "succeeds if slot opens before max_wait_time" do
            start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            expect { subject.shift }.not_to raise_error
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

            expect(elapsed).to be >= (interval - 0.02)
          end
        end
      end

      context "with both check_interval and max_wait_time" do
        let(:check_interval) { 0.05 }
        let(:max_wait_time) { 0.1 }

        it "raises when max_wait_time is reached before a slot opens" do
          expect do
            subject.shift
          end.to raise_error(Hanikamu::RateLimit::RateLimitError)
        end

        context "when max_wait_time is long enough" do
          let(:max_wait_time) { 1.0 }

          it "succeeds if slot opens within max_wait_time" do
            start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            expect { subject.shift }.not_to raise_error
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

            expect(elapsed).to be >= (interval - 0.02)
          end
        end
      end
    end

    context "when running across multiple instances" do
      let(:key_prefix) { "#{Hanikamu::RateLimit::RateQueue::KEY_PREFIX}:multi_instance:#{SecureRandom.hex(4)}" }
      let(:queue_one) do
        described_class.new(
          rate,
          klass_name: "MultiInstance",
          method: "execute",
          interval: interval,
          key_prefix: key_prefix,
          check_interval: check_interval,
          max_wait_time: max_wait_time
        )
      end
      let(:queue_two) do
        described_class.new(
          rate,
          klass_name: "MultiInstance",
          method: "execute",
          interval: interval,
          key_prefix: key_prefix,
          check_interval: check_interval,
          max_wait_time: max_wait_time
        )
      end

      before do
        queue_one.reset
      end

      after do
        queue_one.reset
      end

      it "enforces limits across queues sharing the same key" do
        queue_one.shift
        queue_two.shift

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        queue_one.shift
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        expect(elapsed).to be >= (interval - 0.02)
      end
    end

    context "when called from multiple threads" do
      let(:rate) { 1 }
      let(:interval) { 0.1 }
      let(:key_prefix) { "#{Hanikamu::RateLimit::RateQueue::KEY_PREFIX}:threaded_test:#{SecureRandom.hex(4)}" }
      let(:queue_one) do
        described_class.new(
          rate,
          klass_name: "Threaded",
          method: "execute",
          interval: interval,
          key_prefix: key_prefix,
          check_interval: check_interval,
          max_wait_time: max_wait_time
        )
      end
      let(:queue_two) do
        described_class.new(
          rate,
          klass_name: "Threaded",
          method: "execute",
          interval: interval,
          key_prefix: key_prefix,
          check_interval: check_interval,
          max_wait_time: max_wait_time
        )
      end

      before do
        queue_one.reset
        queue_one.shift
      end

      after do
        queue_one.reset
      end

      it "limits calls across threads" do
        duration = ThreadCoordinator.new(queue_one, queue_two).duration

        expect(duration).to be >= (interval - 0.02)
      end
    end

    context "with callback" do
      let(:sleep_times) { [] }
      let(:callback) { ->(sleep_time) { sleep_times << sleep_time } }

      before do
        rate.times { subject.shift }
      end

      it "calls callback with sleep_time when rate limited" do
        subject.shift

        expect(sleep_times.size).to be >= 1
        expect(sleep_times.first).to be >= 0
        expect(sleep_times.first).to be <= interval
      end
    end

    context "when Redis fails" do
      it "returns nil and logs warning" do
        Hanikamu::RateLimit.configure do |config|
          config.redis_url = "redis://127.0.0.1:6390/2"
        end

        failure_subject = described_class.new(
          rate,
          klass_name:,
          method: method_name,
          interval: interval,
          check_interval: check_interval,
          max_wait_time: max_wait_time
        )

        result = nil

        expect do
          result = failure_subject.shift
        end.to output(/Redis error/).to_stderr

        expect(result).to be_nil
      end
    end
  end

  describe "#reset" do
    it "clears the rate limit queue" do
      rate.times { subject.shift }

      subject.reset

      expect { subject.shift }.not_to raise_error
    end
  end

  describe "override key" do
    let(:override_key) { "#{Hanikamu::RateLimit::RateQueue::KEY_PREFIX}:registry:test_override:override" }
    let(:queue_with_override) do
      described_class.new(
        rate,
        klass_name: klass_name,
        method: method_name,
        interval: interval,
        check_interval: check_interval,
        max_wait_time: max_wait_time,
        override_key: override_key
      )
    end

    before do
      queue_with_override.reset
    end

    after do
      redis.del(override_key)
      queue_with_override.reset
    end

    context "when override allows more requests than the sliding window" do
      it "uses the override instead of the sliding window" do
        redis.set(override_key, 10, ex: 5)

        # Sliding window would block after 2 (rate), but override allows 10
        5.times do
          expect { queue_with_override.shift }.not_to raise_error
        end

        expect(redis.get(override_key).to_i).to eq(5)
      end
    end

    context "when override remaining is exhausted" do
      let(:max_wait_time) { 0.1 }

      it "raises immediately without polling when sleep_time exceeds max_wait_time" do
        redis.set(override_key, 0, ex: 5)

        sleep_times = []
        queue = described_class.new(
          rate,
          klass_name: klass_name,
          method: method_name,
          interval: interval,
          check_interval: check_interval,
          max_wait_time: max_wait_time,
          override_key: override_key
        ) { |sleep_time| sleep_times << sleep_time }

        expect do
          queue.shift
        end.to raise_error(Hanikamu::RateLimit::RateLimitError, /Max wait time exceeded/)

        expect(sleep_times).to be_empty
      end
    end

    context "when override value is non-numeric" do
      it "falls back to normal sliding window behavior" do
        redis.set(override_key, "invalid", ex: 5)

        rate.times do
          expect { queue_with_override.shift }.not_to raise_error
        end

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        queue_with_override.shift
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        expect(elapsed).to be >= (interval - 0.02)
      end
    end

    context "when override has no expiry" do
      it "falls back to normal sliding window behavior" do
        redis.set(override_key, 0)

        rate.times do
          expect { queue_with_override.shift }.not_to raise_error
        end

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        queue_with_override.shift
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        expect(elapsed).to be >= (interval - 0.02)
      end

      it "does not allow requests when remaining is positive" do
        redis.set(override_key, 2)

        rate.times do
          expect { queue_with_override.shift }.not_to raise_error
        end

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        queue_with_override.shift
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        expect(elapsed).to be >= (interval - 0.02)
      end
    end

    context "when override ttl is 0" do
      it "falls back to normal sliding window behavior" do
        redis.set(override_key, 0)
        redis.expire(override_key, 1)
        expect(wait_until? { redis.ttl(override_key) <= 0 }).to be(true)

        rate.times do
          expect { queue_with_override.shift }.not_to raise_error
        end

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        queue_with_override.shift
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        expect(elapsed).to be >= (interval - 0.02)
      end
    end

    context "when override key does not exist" do
      it "falls back to normal sliding window behavior" do
        rate.times do
          expect { queue_with_override.shift }.not_to raise_error
        end

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        queue_with_override.shift
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        expect(elapsed).to be >= (interval - 0.02)
      end

      context "with a short max_wait_time" do
        let(:max_wait_time) { 0.05 }

        it "waits until max_wait_time is exceeded before raising" do
          rate.times do
            expect { queue_with_override.shift }.not_to raise_error
          end

          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          expect do
            queue_with_override.shift
          end.to raise_error(Hanikamu::RateLimit::RateLimitError, /Max wait time exceeded/)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

          expect(elapsed).to be >= max_wait_time
        end
      end
    end

    context "when override expires during usage" do
      it "transitions back to sliding window" do
        redis.set(override_key, 2, ex: 1)

        # Use up the override
        2.times { queue_with_override.shift }

        # Wait for override to expire
        expect(wait_until? { !redis.exists?(override_key) }).to be(true)

        # Should now use sliding window (allows 'rate' requests)
        rate.times do
          expect { queue_with_override.shift }.not_to raise_error
        end
      end
    end

    context "when override is decremented concurrently" do
      it "correctly tracks remaining count" do
        redis.set(override_key, 3, ex: 5)

        3.times { queue_with_override.shift }

        expect(redis.get(override_key).to_i).to eq(0)
      end
    end
  end
end
