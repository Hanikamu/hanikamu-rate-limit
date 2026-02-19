# frozen_string_literal: true

module Hanikamu
  module RateLimit
    class RateLimitError < StandardError
      attr_reader :retry_after

      def initialize(message = "Rate limit exceeded", retry_after: nil)
        @retry_after = retry_after
        super(message)
      end
    end
  end
end
