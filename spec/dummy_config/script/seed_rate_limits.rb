# frozen_string_literal: true

# This script is designed to run via `rails runner` so that ActiveRecord
# is available for EventCapture and SnapshotRecorder.  When launched
# standalone (e.g. `bundle exec ruby`) it falls back to configuring the
# gem directly — without database persistence.
unless defined?(Rails)
  require "hanikamu-rate-limit"

  class SimulatedTimeoutError < StandardError; end

  Hanikamu::RateLimit.configure do |config|
    config.redis_url = ENV.fetch("REDIS_URL", "redis://redis:6379/15")
    config.metrics_enabled = true
    config.register_limit(:test, rate: 100, interval: 1.0, check_interval: 0.05, max_wait_time: 0.5)
    config.register_adaptive_limit(
      :adaptive_api,
      initial_rate: 30,
      interval: 1.0,
      min_rate: 5,
      max_rate: 60,
      increase_by: 2,
      decrease_factor: 0.5,
      probe_window: 10,
      cooldown_after_decrease: 5,
      error_classes: [SimulatedTimeoutError],
      check_interval: 0.05,
      max_wait_time: 0.5,
      response_parser: lambda { |response|
        return nil unless response.is_a?(Hash)

        status = response[:status]
        return nil if status.nil? || status < 400

        { status: status, decrease: status == 429 }
      }
    )
  end
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

# ── Simulated upstream API ─────────────────────────────────────────
# The server has a real Rails 8 `rate_limit` of 20 req/s on
# ApiController#data.  The adaptive rate limiter makes actual HTTP
# requests and learns from the real 429 responses.
#
# Three failure modes produce events in the learning UI:
#   • 429 responses — the server rejected (true rate-limit signal)
#   • 500 responses — random server hiccup (noise)
#   • SimulatedTimeoutError — network timeout (noise)
# Users classify which events are rate-limit signals vs noise.

require "net/http"

API_URI = URI("http://localhost:3000/api/data").freeze

class AdaptiveClient
  extend Hanikamu::RateLimit::Mixin

  limit_method :call, registry: :adaptive_api

  # Makes a real HTTP request to the Rails 8 rate-limited endpoint.
  # No rate-limit headers — status codes are the only signal.
  def call
    # ~1% network timeouts (caught by error_classes)
    raise SimulatedTimeoutError, "connection timed out after 30s" if rand < 0.01

    response = Net::HTTP.get_response(API_URI)
    { status: response.code.to_i, body: response.body }
  end
end

client = DummyClient.new
test_two = TestTwo.new
adaptive_client = AdaptiveClient.new

# Wait for Puma to be ready before making HTTP calls
def wait_for_server(uri, timeout: 30)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    Net::HTTP.get_response(uri)
    warn "[seed] Server is ready"
    return true
  rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      warn "[seed] Server not ready after #{timeout}s — starting anyway"
      return false
    end
    sleep(0.5)
  end
end

wait_for_server(API_URI)

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

adaptive_thread = Thread.new do
  loop do
    begin
      adaptive_client.call
    rescue SimulatedTimeoutError
      # Network error — caught by error_classes, AIMD decreases rate
    rescue Hanikamu::RateLimit::RateLimitError
      # rate-limited by the sliding window
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
      sleep(1) # server temporarily unavailable — back off
    end
    sleep(rand(0.01..0.04))
  end
end

# Record rate snapshots so the dashboard shows historical limit lines.
# When running under Rails the Storage models are available.
snapshot_thread = Thread.new do
  loop do
    sleep(10)
    Hanikamu::RateLimit::Storage::SnapshotRecorder.tick!
  rescue StandardError => e
    warn "[seed] SnapshotRecorder: #{e.message}"
  end
end

[traffic_thread, override_thread, test_two_thread, adaptive_thread, snapshot_thread].each(&:join)
