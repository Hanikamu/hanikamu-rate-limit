# frozen_string_literal: true

module Hanikamu
  module RateLimit
    module UI
      # Shared helpers for override presentation logic.
      module OverrideHelpers
        TIME_THRESHOLDS = [
          [60,     ->(s) { "#{s}s ago" }],
          [3600,   ->(s) { "#{s / 60}m ago" }],
          [86_400, ->(s) { "#{s / 3600}h ago" }]
        ].freeze

        def override
          data["override"]
        end

        def override?
          !override.nil?
        end

        def override_active?
          override&.fetch("active", false) == true
        end

        def override_remaining
          override&.fetch("remaining", nil)
        end

        def override_reset
          override&.fetch("reset", nil)
        end

        def override_updated_at
          override&.fetch("updated_at", nil)
        end

        def override_age_label
          ts = override_updated_at
          return nil unless ts

          seconds = [Time.now.to_i - ts, 0].max
          time_ago_in_words(seconds)
        end

        private

        def time_ago_in_words(seconds)
          TIME_THRESHOLDS.each do |threshold, formatter|
            return formatter.call(seconds) if seconds < threshold
          end
          "#{seconds / 86_400}d ago"
        end
      end
    end
  end
end
