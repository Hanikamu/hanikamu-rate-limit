# frozen_string_literal: true

require "active_record"

module Hanikamu
  module RateLimit
    module Storage
      # Periodically records the current_rate for every adaptive limit into
      # the database. The dashboard uses these snapshots to render a
      # historical rate chart showing how the AIMD algorithm adapted.
      #
      # Designed to be called on a timer (e.g. from the SSE tick, a cron job,
      # or a background thread). The `tick!` class method is idempotent:
      # it only writes a snapshot when enough time has elapsed since the last one.
      class SnapshotRecorder
        class << self
          # Records a snapshot for every adaptive limit if the configured
          # interval has elapsed since the last snapshot for that limit.
          def tick!
            interval = Hanikamu::RateLimit.config.snapshot_interval
            adaptive_entries.each do |name, state|
              record_if_due(name, state, interval)
            end
          end

          # Force-records a snapshot for a single registry, ignoring interval.
          def record!(registry_name, state)
            snapshot = state.state
            with_connection do
              RateSnapshot.create!(
                registry_name: registry_name.to_s,
                rate: snapshot[:current_rate],
                min_rate: state.config[:min_rate],
                max_rate: state.config[:max_rate],
                cooldown_active: snapshot[:cooldown_active]
              )
            end
          rescue StandardError => e
            log_error(e)
          end

          private

          def with_connection(&)
            ActiveRecord::Base.connection_pool.with_connection(&)
          end

          def adaptive_entries
            Hanikamu::RateLimit.adaptive_states
          end

          def record_if_due(name, state, interval)
            last = with_connection do
              RateSnapshot.for_registry(name).order(created_at: :desc).pick(:created_at)
            end
            return if last && (Time.current - last) < interval

            record!(name, state)
          end

          def log_error(error)
            msg = "[HanikamuRateLimit::SnapshotRecorder] #{error.class}: #{error.message}"
            if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
              Rails.logger.error(msg)
            else
              warn msg
            end
          end
        end
      end
    end
  end
end
