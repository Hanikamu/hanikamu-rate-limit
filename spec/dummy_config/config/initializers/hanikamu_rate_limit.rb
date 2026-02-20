# frozen_string_literal: true

# Simulated error: network timeout (noise — not a rate-limit signal).
# The server hard limit is 20 req/s — 429 responses are the true signal.
class SimulatedTimeoutError < StandardError; end

Hanikamu::RateLimit.configure do |config|
  config.redis_url = ENV.fetch("REDIS_URL", "redis://redis:6379/15")
  config.metrics_enabled = true
  config.ui_auth = ->(_controller) { true }

  config.register_limit(:test, rate: 100, interval: 1.0, check_interval: 0.05, max_wait_time: 0.5)

  # The simulated upstream API does NOT expose rate-limit headers.
  # AIMD learns from:
  #   - response_parser: detects 429 status (decrease) and 500 status (captured as noise)
  #   - error_classes: catches Ruby-level network errors (timeouts)
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
