# frozen_string_literal: true

module Hanikamu
  module RateLimit
    # Provides automatic retry-with-backoff for job classes that hit rate limits.
    #
    # Supports two worker backends:
    #   :active_job (default) — uses rescue_from + retry_job(wait:)
    #   :sidekiq              — uses sidekiq_retry_in + sidekiq_options (requires sidekiq >= 8.1)
    #
    # In both cases, instead of sleeping the thread (which can starve workers),
    # the job raises immediately and re-enqueues with the correct delay.
    #
    # @example ActiveJob (default)
    #   class MyJob < ApplicationJob
    #     extend Hanikamu::RateLimit::JobRetry
    #     rate_limit_retry
    #
    #     def perform
    #       MyService.new.execute
    #     end
    #   end
    #
    # @example Sidekiq native worker
    #   class MyWorker
    #     include Sidekiq::Job
    #     extend Hanikamu::RateLimit::JobRetry
    #     rate_limit_retry worker: :sidekiq
    #
    #     def perform
    #       MyService.new.execute
    #     end
    #   end
    #
    module JobRetry
      VALID_WORKERS = %i[active_job sidekiq].freeze
      SIDEKIQ_MIN_VERSION = Gem::Version.new("8.1")

      # When Sidekiq has no true "unlimited", use a very large retry count.
      SIDEKIQ_UNLIMITED_RETRIES = 1_000_000

      # Configures the job class to automatically retry on RateLimitError.
      #
      # @param attempts [:unlimited, Integer] total executions (initial run + retries).
      #   :unlimited retries forever; an integer caps the total. For Sidekiq this
      #   maps to `sidekiq_options retry: attempts - 1`.
      # @param fallback_wait [Numeric] seconds to wait if `retry_after` is nil (default: 5)
      # @param worker [:active_job, :sidekiq] which backend to wire up (default: :active_job)
      def rate_limit_retry(attempts: :unlimited, fallback_wait: 5, worker: :active_job)
        validate_retry_options!(attempts, fallback_wait)
        validate_worker!(worker)

        case worker
        when :active_job then install_active_job_retry(attempts, fallback_wait)
        when :sidekiq then install_sidekiq_retry(attempts, fallback_wait)
        end
      end

      private

      # ActiveJob path: adds a rescue_from handler that calls retry_job(wait:).
      def install_active_job_retry(max_attempts, fallback_wait)
        rescue_from(Hanikamu::RateLimit::RateLimitError) do |exception|
          wait = exception.retry_after || fallback_wait

          raise exception unless max_attempts == :unlimited || executions < max_attempts

          retry_job(wait: wait)
        end

        install_raise_strategy_wrapper
      end

      # Sidekiq path: uses sidekiq_retry_in to control backoff timing and
      # sidekiq_options to set the max retry count. Sidekiq's `retry: N` means
      # N retries *after* the initial run, so we subtract 1 from attempts to
      # keep the semantics consistent with ActiveJob (attempts = total executions).
      def install_sidekiq_retry(max_attempts, fallback_wait)
        require_sidekiq!
        validate_sidekiq_dsl!

        max_retries = max_attempts == :unlimited ? SIDEKIQ_UNLIMITED_RETRIES : [max_attempts - 1, 0].max
        sidekiq_options retry: max_retries

        fw = fallback_wait
        sidekiq_retry_in do |_count, exception|
          exception.retry_after || fw if exception.is_a?(Hanikamu::RateLimit::RateLimitError)
        end

        install_raise_strategy_wrapper
      end

      # Shared: wraps perform to set the thread-local wait strategy to :raise,
      # so RateQueue raises immediately instead of sleeping the thread.
      def install_raise_strategy_wrapper
        prepend(Module.new do
          def perform(*, **)
            Hanikamu::RateLimit.with_wait_strategy(:raise) { super }
          end
        end)
      end

      def require_sidekiq!
        raise LoadError, "worker: :sidekiq requires the sidekiq gem to be loaded" unless defined?(::Sidekiq::VERSION)

        return if Gem::Version.new(::Sidekiq::VERSION) >= SIDEKIQ_MIN_VERSION

        raise LoadError,
              "worker: :sidekiq requires sidekiq >= 8.1, found #{::Sidekiq::VERSION}"
      end

      def validate_worker!(worker)
        return if VALID_WORKERS.include?(worker)

        raise ArgumentError,
              "worker must be one of #{VALID_WORKERS.join(", ")}, got #{worker.inspect}"
      end

      # Ensures the host class exposes the Sidekiq class-level DSL methods
      # that install_sidekiq_retry relies on. Without this, a plain class
      # would get a confusing NoMethodError at definition time.
      def validate_sidekiq_dsl!
        missing = %i[sidekiq_options sidekiq_retry_in].reject { |m| respond_to?(m) }
        return if missing.empty?

        raise ArgumentError,
              "worker: :sidekiq requires the host class to include Sidekiq::Job (or Sidekiq::Worker). " \
              "Missing methods: #{missing.join(", ")}"
      end

      def validate_retry_options!(attempts, fallback_wait)
        unless attempts == :unlimited || (attempts.is_a?(Integer) && attempts.positive?)
          raise ArgumentError, "attempts must be :unlimited or a positive Integer, got #{attempts.inspect}"
        end

        return if fallback_wait.is_a?(Numeric) && !fallback_wait.negative?

        raise ArgumentError, "fallback_wait must be a non-negative Numeric, got #{fallback_wait.inspect}"
      end
    end
  end
end
