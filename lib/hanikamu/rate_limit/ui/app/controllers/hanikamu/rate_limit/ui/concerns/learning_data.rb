# frozen_string_literal: true

module Hanikamu
  module RateLimit
    module UI
      module Concerns
        # Extracted data-loading helpers for the LearningController.
        # Keeps the controller class under the RuboCop Metrics/ClassLength limit.
        module LearningData
          private

          def load_grouped_events
            scope = filtered_event_scope
            groups = grouped_event_counts(scope)
            groups.map { |g| enrich_group_with_recent(g, scope) }
          end

          def filtered_event_scope
            scope = Storage::CapturedEvent.all
            scope = scope.for_registry(@current_registry) if @current_registry.present?
            apply_filter(scope)
          end

          def grouped_event_counts(scope)
            scope
              .select(
                "event_type, exception_class, response_status, classification",
                "COUNT(*) AS event_count",
                "MAX(created_at) AS last_seen_at"
              )
              .group(:event_type, :exception_class, :response_status, :classification)
              .order(Arel.sql("event_count DESC"))
              .map { |row| base_group_hash(row) }
          end

          def base_group_hash(row)
            { event_type: row.event_type, exception_class: row.exception_class,
              response_status: row.response_status, classification: row.classification,
              count: row.attributes["event_count"].to_i,
              last_seen_at: row.attributes["last_seen_at"], recent_events: [] }
          end

          # Load up to 5 most recent individual events for each group so
          # encrypted columns (message, headers, body) are decrypted by AR.
          def enrich_group_with_recent(group, scope)
            events = scope.where(
              event_type: group[:event_type],
              exception_class: group[:exception_class],
              response_status: group[:response_status],
              classification: group[:classification]
            ).order(created_at: :desc).limit(5)
            group.merge(recent_events: events)
          end

          def apply_filter(scope)
            case @filter
            when "unclassified" then scope.unclassified
            when "rate_limit"   then scope.rate_limit_signals
            when "ignored"      then scope.ignored
            else scope
            end
          end

          def load_snapshot_series
            return [] unless @current_registry.present?

            Storage::RateSnapshot.chart_series(@current_registry, since: 24.hours.ago)
          rescue StandardError
            []
          end

          # Returns [[epoch, rate_at_that_moment], ...] for events classified as rate_limit.
          # We match each event timestamp to the closest snapshot rate.
          def load_event_markers
            return [] unless @current_registry.present? && @snapshot_series.any?

            events = Storage::CapturedEvent
              .for_registry(@current_registry)
              .rate_limit_signals
              .where(created_at: 24.hours.ago..)
              .order(:created_at)
              .pluck(:created_at)

            events.map { |ts| [ts.to_i, closest_rate(ts.to_i)] }
          rescue StandardError
            []
          end

          def closest_rate(epoch)
            best = @snapshot_series.first
            @snapshot_series.each { |s| best = s if (s[0] - epoch).abs < (best[0] - epoch).abs }
            best&.last || 0
          end
        end
      end
    end
  end
end
