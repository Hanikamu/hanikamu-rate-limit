# frozen_string_literal: true

require "active_record"

module Hanikamu
  module RateLimit
    module Storage
      # Deletes captured events and rate snapshots older than the configured
      # retention periods. Run periodically (e.g. daily via cron or
      # a Sidekiq job) to keep the tables lean.
      #
      #   Hanikamu::RateLimit::Storage::RetentionCleanup.run!
      #
      class RetentionCleanup
        class << self
          # Purges expired events and snapshots. Returns a hash with counts.
          def run!
            {
              events: purge_events,
              snapshots: purge_snapshots
            }
          end

          private

          def purge_events
            cutoff = Time.current - Hanikamu::RateLimit.config.event_retention
            CapturedEvent.where(created_at: ...cutoff).delete_all
          end

          def purge_snapshots
            cutoff = Time.current - Hanikamu::RateLimit.config.snapshot_retention
            RateSnapshot.where(created_at: ...cutoff).delete_all
          end
        end
      end
    end
  end
end
