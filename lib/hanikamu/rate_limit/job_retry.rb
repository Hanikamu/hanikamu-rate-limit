# frozen_string_literal: true

module Hanikamu
  module RateLimit
    # Provides automatic retry-with-backoff for ActiveJob classes that hit rate limits.
    #
    # When a job is rate-limited, instead of sleeping the thread (which can starve
    # Sidekiq/GoodJob workers), it raises immediately and re-enqueues the job with
    # `retry_job(wait: exception.retry_after)`, freeing the thread for other work.
    #
    # @example In an AsyncService concern
    #   const_set(
    #     :Async,
    #     Class.new(ApplicationJob) do
    #       extend Hanikamu::RateLimit::JobRetry
    #       rate_limit_retry
    #
    #       def perform(args:)
    #         self.class.module_parent.call(args)
    #       end
    #     end
    #   )
    #
    # @example With custom attempts and fallback wait
    #   extend Hanikamu::RateLimit::JobRetry
    #   rate_limit_retry attempts: 50, fallback_wait: 10
    #
    module JobRetry
      # Configures the job class to automatically retry on RateLimitError.
      #
      # This does two things:
      # 1. Adds a `rescue_from` handler that calls `retry_job` with the
      #    `retry_after` duration from the exception (falling back to `fallback_wait`).
      # 2. Wraps `perform` to set the thread-local wait strategy to `:raise`,
      #    so RateQueue raises immediately instead of sleeping the thread.
      #
      # @param attempts [:unlimited, Integer] max retry attempts (:unlimited for infinite)
      # @param fallback_wait [Numeric] seconds to wait if `retry_after` is nil (default: 5)
      def rate_limit_retry(attempts: :unlimited, fallback_wait: 5)
        validate_retry_options!(attempts, fallback_wait)
        max_attempts = attempts

        rescue_from(Hanikamu::RateLimit::RateLimitError) do |exception|
          wait = exception.retry_after || fallback_wait

          raise exception unless max_attempts == :unlimited || executions < max_attempts

          retry_job(wait: wait)

        end

        prepend(Module.new do
          def perform(*, **)
            Hanikamu::RateLimit.with_wait_strategy(:raise) { super }
          end
        end)
      end

      private

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
