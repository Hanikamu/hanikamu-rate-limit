# frozen_string_literal: true

module Hanikamu
  module RateLimit
    module UI
      class DashboardPresenter
        attr_reader :payload

        def initialize(payload)
          @payload = payload
        end

        def limits_count
          limits.size
        end

        def window_hours
          (payload.fetch("window_seconds") / 3600.0).round(1)
        end

        def bucket_seconds
          payload.fetch("bucket_seconds")
        end

        def realtime_bucket_seconds
          payload.fetch("metrics_realtime_bucket_seconds")
        end

        def generated_at_utc
          Time.at(payload.fetch("generated_at")).utc.strftime("%Y-%m-%d %H:%M UTC")
        end

        def redis_info
          payload["redis"]
        end

        def redis_info?
          !redis_info.nil?
        end

        def limits
          @limits ||= payload.fetch("limits").map { |l| LimitPresenter.new(l, self) }
        end

        def limits?
          limits.any?
        end
      end
    end
  end
end
