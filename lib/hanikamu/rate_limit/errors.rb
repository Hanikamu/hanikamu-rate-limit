# frozen_string_literal: true

module Hanikamu
  module RateLimit
    # Raised when a request cannot be served within the allowed wait time.
    #
    # @attr_reader retry_after [Float, nil] Seconds until the next slot opens.
    #   Used by JobRetry to schedule `retry_job(wait: retry_after)` and by
    #   RateQueue to propagate the Lua script's calculated sleep time.
    class RateLimitError < StandardError
      attr_reader :retry_after

      def initialize(message = "Rate limit exceeded", retry_after: nil)
        @retry_after = retry_after
        super(message)
      end
    end
  end
end
