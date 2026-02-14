# frozen_string_literal: true

require "hanikamu-rate-limit"

Hanikamu::RateLimit.configure do |config|
  config.redis_url = ENV.fetch("REDIS_URL", "redis://redis:6379/15")
  config.metrics_enabled = true
  config.register_limit(:test, rate: 100, interval: 1.0, check_interval: 0.05, max_wait_time: 0.5)
end

# Clear stale metrics from previous runs
# Use SCAN instead of KEYS to avoid blocking Redis in production-like environments.
redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://redis:6379/15"))
%w[hanikamu:rate_limit:metrics:* hanikamu:rate_limit:rate_queue:*].each do |pattern|
  batch = []
  redis.scan_each(match: pattern) do |key|
    batch << key
    if batch.size >= 100
      redis.del(*batch)
      batch.clear
    end
  end
  redis.del(*batch) unless batch.empty?
end

class DummyClient
  extend Hanikamu::RateLimit::Mixin

  limit_method :call, registry: :test

  def call
    sleep(rand(0.001..0.005))
    :ok
  end
end

class TestTwo
  extend Hanikamu::RateLimit::Mixin

  limit_method :execute, rate: 1, interval: 5, metrics: true

  def execute; end
end

client = DummyClient.new
test_two = TestTwo.new

traffic_thread = Thread.new do
  target_rps = rand(10..120)

  loop do
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
    calls = 0

    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      begin
        client.call
        calls += 1
      rescue Hanikamu::RateLimit::RateLimitError
        # blocked — count toward the second but don't stop
      end

      gap = (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)) / [target_rps - calls, 1].max
      sleep(gap) if gap > 0
    end

    # Drift target RPS each second for a natural-looking curve
    target_rps = (target_rps + rand(-15..15)).clamp(10, 120)
  end
end

override_thread = Thread.new do
  loop do
    sleep(10)
    remaining = rand(10..200)
    reset     = rand(1..15)
    Hanikamu::RateLimit.register_temporary_limit(:test, remaining: remaining, reset: reset)
  end
end

test_two_thread = Thread.new do
  loop do
    begin
      test_two.execute
    rescue Hanikamu::RateLimit::RateLimitError
      # blocked
    end
    sleep(rand(1.0..3.0))
  end
end

[traffic_thread, override_thread, test_two_thread].each(&:join)
