# frozen_string_literal: true

Hanikamu::RateLimit.configure do |config|
  config.redis_url = ENV.fetch("REDIS_URL", "redis://redis:6379/15")
  config.metrics_enabled = true
  config.ui_auth = ->(_controller) { true }

  config.register_limit(:test, rate: 100, interval: 1.0, check_interval: 0.05, max_wait_time: 0.5)
end
