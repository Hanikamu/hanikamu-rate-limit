# frozen_string_literal: true

# Simulated upstream API endpoint.
# Uses Rails 8's built-in rate_limit to enforce a hard cap.
# The adaptive rate limiter learns from the real 429 responses.
#
# Logging is silenced because the seed script fires 25-100 req/s;
# without this the Rails log is unreadable.
class ApiController < ActionController::Base
  # 20 requests per second — the "hidden" server limit that AIMD must discover.
  rate_limit to: 20, within: 1.second, by: -> { "global" }, with: -> { head :too_many_requests }

  skip_forgery_protection
  around_action :silence_logging

  def data
    # ~3 % random 500s (noise — captured by response_parser, not a rate signal)
    if rand < 0.03
      render json: { error: "Internal Server Error" }, status: :internal_server_error
      return
    end

    render json: { status: "ok" }
  end

  private

  def silence_logging(&)
    Rails.logger.silence(&)
  end
end
