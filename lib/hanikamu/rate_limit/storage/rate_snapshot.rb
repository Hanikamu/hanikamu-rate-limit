# frozen_string_literal: true

require "active_record"

module Hanikamu
  module RateLimit
    module Storage
      # Periodic recording of the adaptive current_rate for a registry.
      # Enables the historical rate chart on the dashboard — shows how the
      # adaptive algorithm adjusted the rate over time.
      class RateSnapshot < ActiveRecord::Base
        self.table_name = "hanikamu_rate_limit_snapshots"

        validates :registry_name, presence: true
        validates :rate, numericality: { only_integer: true, greater_than: 0 }

        scope :for_registry, ->(name) { where(registry_name: name.to_s) }
        scope :since, ->(time) { where(created_at: time..) }
        scope :chronological, -> { order(created_at: :asc) }

        # Returns chart-ready data: [[timestamp_epoch, rate], ...]
        def self.chart_series(registry_name, since: 24.hours.ago)
          for_registry(registry_name)
            .since(since)
            .chronological
            .pluck(:created_at, :rate)
            .map { |ts, r| [ts.to_i, r] }
        end

        # Returns full adaptive history including ceiling state:
        # [{ epoch:, rate:, error_ceiling:, ceiling_hits:,
        #    ceiling_confidence:, effective_cooldown: }, ...]
        def self.adaptive_chart_series(registry_name, since: 24.hours.ago)
          for_registry(registry_name)
            .since(since)
            .chronological
            .pluck(:created_at, :rate, :error_ceiling,
                   :ceiling_hits, :ceiling_confidence, :effective_cooldown)
            .map { |row| adaptive_row_to_hash(row) }
        end

        def self.adaptive_row_to_hash(row)
          ts, r, ceil, hits, conf, cd = row
          { epoch: ts.to_i, rate: r, error_ceiling: ceil,
            ceiling_hits: hits.to_i, ceiling_confidence: conf.to_i,
            effective_cooldown: cd }
        end
        private_class_method :adaptive_row_to_hash
      end
    end
  end
end
