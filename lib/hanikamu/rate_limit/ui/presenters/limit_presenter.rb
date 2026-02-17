# frozen_string_literal: true

require_relative "override_helpers"

module Hanikamu
  module RateLimit
    module UI
      class LimitPresenter
        include OverrideHelpers

        EMPTY_HISTORY = { "allowed" => [], "blocked" => [], "buckets" => [] }.freeze
        EMPTY_LIFETIME = { "allowed" => 0, "blocked" => 0 }.freeze

        attr_reader :data, :dashboard

        def initialize(data, dashboard)
          @data = data
          @dashboard = dashboard
        end

        def identifier
          data["registry"] || "#{data["klass_name"]}##{data["method"]}"
        end

        def key_prefix
          data.fetch("key_prefix")
        end

        def rate
          data.fetch("rate")
        end

        def interval
          data.fetch("interval")
        end

        def interval_formatted
          format("%.2f", interval)
        end

        def limit_per_bucket
          rate * (dashboard.bucket_seconds.to_f / interval)
        end

        def limit_per_bucket_formatted
          format("%.2f", limit_per_bucket)
        end

        def effective_realtime_bucket_seconds
          [interval.ceil, dashboard.realtime_bucket_seconds].max
        end

        def realtime_limit_per_bucket
          rate * (effective_realtime_bucket_seconds.to_f / interval)
        end

        def realtime_limit_per_bucket_formatted
          format("%.2f", realtime_limit_per_bucket)
        end

        # ── History ──────────────────────────────────────────────

        def history
          @history ||= data.fetch("history", EMPTY_HISTORY)
        end

        def realtime_history
          @realtime_history ||= data.fetch("realtime_history", EMPTY_HISTORY)
        end

        def allowed_total_24h
          history.fetch("allowed", []).sum
        end

        def blocked_total_24h
          history.fetch("blocked", []).sum
        end

        def realtime_allowed
          realtime_history.fetch("allowed", [])
        end

        def realtime_blocked
          realtime_history.fetch("blocked", [])
        end

        def last_realtime_hits
          penultimate_or_last(realtime_allowed)
        end

        def last_realtime_blocked
          penultimate_or_last(realtime_blocked)
        end

        def allowed_total_5m
          realtime_allowed.sum
        end

        def blocked_total_5m
          realtime_blocked.sum
        end

        # ── Lifetime ─────────────────────────────────────────────

        def lifetime
          @lifetime ||= data.fetch("lifetime", EMPTY_LIFETIME)
        end

        def lifetime_allowed
          lifetime.fetch("allowed", 0)
        end

        def lifetime_blocked
          lifetime.fetch("blocked", 0)
        end

        # ── Metrics ──────────────────────────────────────────────

        def metrics_enabled?
          data.fetch("metrics_enabled", false)
        end

        private

        def penultimate_or_last(series)
          series.length > 1 ? series[-2].to_i : series.last.to_i
        end
      end
    end
  end
end
