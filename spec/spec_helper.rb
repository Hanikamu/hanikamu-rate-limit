# frozen_string_literal: true

require "hanikamu-rate-limit"
require "redis"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:suite) do
    redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/15")

    Hanikamu::RateLimit.configure do |rl_config|
      rl_config.redis_url = redis_url
      rl_config.max_wait_time = 2.0
      rl_config.check_interval = 0.5
    end

    begin
      Redis.new(url: redis_url).call("FLUSHDB")
    rescue StandardError
      # ignore if Redis is not available locally; CI provides Redis
    end
  end

  config.after(:suite) do
    redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/15")
    Redis.new(url: redis_url).call("FLUSHDB")
  rescue StandardError
    # ignore if Redis is not available
  end
end

# Helper: wait_until for polling-based expectations to reduce flakiness
def wait_until?(timeout: 2, interval: 0.05)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  loop do
    return true if yield
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - start > timeout

    sleep interval
  end
  false
end
