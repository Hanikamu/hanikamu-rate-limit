# frozen_string_literal: true

require "spec_helper"
require "logger"
require "time"
require "active_job"
require "sidekiq"

# ── ActiveJob integration ────────────────────────────────────────────────────

class RateLimitedActiveJob < ActiveJob::Base
  extend Hanikamu::RateLimit::JobRetry

  rate_limit_retry fallback_wait: 7

  self.queue_name = "rate_limit_test"

  def perform(service_class_name)
    Object.const_get(service_class_name).new.call
  end
end

class CappedActiveJob < ActiveJob::Base
  extend Hanikamu::RateLimit::JobRetry

  rate_limit_retry attempts: 2, fallback_wait: 3

  self.queue_name = "rate_limit_test"

  def perform
    raise Hanikamu::RateLimit::RateLimitError.new("limited", retry_after: 4.0)
  end
end

# ── Sidekiq integration ─────────────────────────────────────────────────────

module RateLimitSidekiqTest
  class Worker
    include Sidekiq::Job
    extend Hanikamu::RateLimit::JobRetry

    rate_limit_retry worker: :sidekiq, fallback_wait: 8

    def perform(service_class_name)
      Object.const_get(service_class_name).new.call
    end
  end

  class CappedWorker
    include Sidekiq::Job
    extend Hanikamu::RateLimit::JobRetry

    rate_limit_retry worker: :sidekiq, attempts: 5, fallback_wait: 6

    def perform
      raise Hanikamu::RateLimit::RateLimitError.new("limited", retry_after: 2.5)
    end
  end
end

# ── Shared rate-limited service ──────────────────────────────────────────────

class IntegrationTestService
  extend Hanikamu::RateLimit::Mixin

  limit_method :call, rate: 1, interval: 10

  attr_reader :called

  def initialize
    @called = false
  end

  def call
    @called = true
  end
end

RSpec.describe Hanikamu::RateLimit::JobRetry, :integration do
  let(:redis_url) { ENV.fetch("REDIS_URL", "redis://localhost:6379/15") }
  let(:redis) { Redis.new(url: redis_url) }

  # Save and restore ActiveJob global state to avoid leaking across the suite.
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    original_logger = ActiveJob::Base.logger
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.logger = Logger.new(File::NULL)
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    ActiveJob::Base.logger = original_logger
  end

  before do
    Hanikamu::RateLimit.configure do |config|
      config.redis_url = redis_url
      config.max_wait_time = 2.0
      config.check_interval = 0.5
      config.wait_strategy = :sleep
      config.jitter = 0.0
    end
    redis.flushdb

    # Clear ActiveJob test adapter queue
    queue_adapter = ActiveJob::Base.queue_adapter
    queue_adapter.enqueued_jobs.clear if queue_adapter.respond_to?(:enqueued_jobs)
  end

  after do
    redis.flushdb
  end

  # ── ActiveJob ────────────────────────────────────────────────

  describe "ActiveJob with real ActiveJob::Base" do
    it "sets :raise strategy during perform" do
      captured = nil

      job_class = Class.new(ActiveJob::Base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry

        self.queue_name = "strategy_test"

        define_method(:perform) do
          captured = Hanikamu::RateLimit.current_wait_strategy
        end
      end

      job_class.perform_now

      expect(captured).to eq(:raise)
      expect(Hanikamu::RateLimit.current_wait_strategy).to be_nil
    end

    it "enqueues a retry when the rate limit is hit" do
      # Exhaust the limit (1 request per 10s window)
      IntegrationTestService.new.call

      # Now the next call should be rate-limited; inside the job that means
      # raise → rescue_from → retry_job(wait: ...)
      RateLimitedActiveJob.perform_now("IntegrationTestService")

      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
      expect(enqueued.size).to eq(1)

      job = enqueued.first
      expect(job["job_class"]).to eq("RateLimitedActiveJob")
      # The test adapter stores scheduled_at as an ISO 8601 string
      expect(job["scheduled_at"]).to be_present
    end

    it "re-raises when attempts are exhausted" do
      job = CappedActiveJob.new
      job.executions = 5 # exceeds the attempts: 2 cap

      expect do
        job.perform_now
      end.to raise_error(Hanikamu::RateLimit::RateLimitError)
    end

    it "retries with fallback_wait when retry_after is nil" do
      job_class = Class.new(ActiveJob::Base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry fallback_wait: 42

        self.queue_name = "fallback_test"

        define_method(:perform) do
          raise Hanikamu::RateLimit::RateLimitError.new("limited", retry_after: nil)
        end
      end

      job_class.perform_now

      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
      expect(enqueued.size).to eq(1)

      # The job was re-enqueued with a scheduled_at in the future
      scheduled_at = Time.parse(enqueued.first["scheduled_at"])
      scheduled_delta = scheduled_at - Time.now
      expect(scheduled_delta).to be_within(2).of(42)
    end
  end

  # ── Sidekiq ──────────────────────────────────────────────────

  describe "Sidekiq with real Sidekiq::Job" do
    it "configures sidekiq_options retry" do
      expect(RateLimitSidekiqTest::CappedWorker.get_sidekiq_options["retry"]).to eq(4)
    end

    it "sets :raise strategy during perform" do
      captured = nil

      worker_class = Class.new do
        include Sidekiq::Job
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq

        define_method(:perform) do
          captured = Hanikamu::RateLimit.current_wait_strategy
        end
      end
      # Sidekiq needs the constant for perform_inline; use .new.perform instead
      worker_class.new.perform

      expect(captured).to eq(:raise)
      expect(Hanikamu::RateLimit.current_wait_strategy).to be_nil
    end

    it "raises RateLimitError when the rate limit is hit" do
      # Exhaust the limit
      IntegrationTestService.new.call

      # Sidekiq's perform_inline re-raises; in production Sidekiq catches it
      # and applies the sidekiq_retry_in block for scheduling.
      expect do
        RateLimitSidekiqTest::Worker.new.perform("IntegrationTestService")
      end.to raise_error(Hanikamu::RateLimit::RateLimitError)
    end

    it "provides retry_after matching the rate queue's remaining TTL" do
      IntegrationTestService.new.call

      raised_error = nil
      begin
        RateLimitSidekiqTest::Worker.new.perform("IntegrationTestService")
        raise "Expected RateLimitError was not raised"
      rescue Hanikamu::RateLimit::RateLimitError => e
        raised_error = e
      end

      expect(raised_error.retry_after).to be_a(Numeric)
      expect(raised_error.retry_after).to be_between(0, 10)
    end

    it "does not interfere with non-rate-limit errors" do
      worker_class = Class.new do
        include Sidekiq::Job
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq

        define_method(:perform) do
          raise ArgumentError, "bad input"
        end
      end

      expect { worker_class.new.perform }.to raise_error(ArgumentError, "bad input")
    end

    it "restores wait strategy even when perform raises" do
      expect do
        RateLimitSidekiqTest::CappedWorker.new.perform
      end.to raise_error(Hanikamu::RateLimit::RateLimitError)

      expect(Hanikamu::RateLimit.current_wait_strategy).to be_nil
    end
  end
end
