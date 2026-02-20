# frozen_string_literal: true

require "hanikamu/rate_limit/storage"
require_relative "concerns/learning_data"

module Hanikamu
  module RateLimit
    module UI
      # Controller for the Learning UI — lets users review captured events
      # and classify them as rate-limit signals or noise.
      class LearningController < ActionController::Base
        include Concerns::LearningData

        append_view_path File.expand_path("../../../../views", __dir__)
        layout false
        GROUP_FILTERS = %i[event_type exception_class response_status].freeze

        before_action :authorize_ui!
        helper_method :engine_root, :learning_url

        # GET /learning
        def index
          @registry_names = registry_names
          @current_registry = params[:registry].presence || @registry_names.first
          @filter = params[:filter].presence || "unclassified"
          @grouped_events = load_grouped_events
          @snapshot_series = load_snapshot_series
          @event_markers = load_event_markers
        end

        # PATCH /learning/:id/classify
        def classify
          event = Storage::CapturedEvent.find(params[:id])
          classification = params[:classification]

          unless Storage::CapturedEvent::CLASSIFICATIONS.include?(classification)
            return render(plain: "Invalid classification", status: :unprocessable_entity)
          end

          event.update!(classification: classification)
          apply_adaptive_side_effects(params[:registry], [event], classification)
          redirect_to learning_url(registry: params[:registry], filter: params[:filter])
        end

        # POST /learning/classify_batch
        def classify_batch
          ids = Array(params[:event_ids]).map(&:to_i)
          classification = params[:classification]

          unless Storage::CapturedEvent::CLASSIFICATIONS.include?(classification)
            return render(plain: "Invalid classification", status: :unprocessable_entity)
          end

          events = Storage::CapturedEvent.where(id: ids)
          events.update_all(classification: classification)
          apply_adaptive_side_effects(params[:registry], events, classification)
          redirect_to learning_url(registry: params[:registry], filter: params[:filter])
        end

        # POST /learning/classify_group
        def classify_group
          classification = params[:classification]

          unless Storage::CapturedEvent::CLASSIFICATIONS.include?(classification)
            return render(plain: "Invalid classification", status: :unprocessable_entity)
          end

          scope = build_group_scope
          events = scope.to_a
          scope.update_all(classification: classification)
          apply_adaptive_side_effects(params[:registry], events, classification)
          redirect_to learning_url(registry: params[:registry], filter: params[:filter])
        end

        # DELETE /learning/purge
        def purge
          Storage::RetentionCleanup.run!
          redirect_to learning_url
        end

        private

        # Base URL of the engine mount point.
        def engine_root
          request.path.sub(%r{/learning.*}, "")
        end

        # Build a learning URL with optional params.
        def learning_url(**query)
          base = "#{engine_root}/learning"
          qs = query.compact.reject { |_, v| v.blank? }.map { |k, v| "#{k}=#{ERB::Util.url_encode(v)}" }.join("&")
          qs.empty? ? base : "#{base}?#{qs}"
        end

        def registry_names
          Storage::CapturedEvent.distinct.pluck(:registry_name).sort
        end

        def build_group_scope
          scope = Storage::CapturedEvent.all
          scope = scope.for_registry(params[:registry]) if params[:registry].present?
          GROUP_FILTERS.each { |col| scope = scope.where(col => params[col]) if params[col].present? }
          scope
        end

        # When events are classified as "rate_limit", drop the adaptive
        # rate to the lowest adaptive_rate among the classified events.
        # Also syncs ceiling confidence for the dynamic threshold.
        def apply_adaptive_side_effects(registry_name, events, classification)
          return if registry_name.blank?

          state = Hanikamu::RateLimit.fetch_adaptive_state(registry_name)

          drop_rate_from_events(state, events) if classification == Storage::CapturedEvent::RATE_LIMIT

          sync_ceiling_confidence(state, registry_name)
        rescue ArgumentError
          # Not an adaptive limit — nothing to do.
          nil
        end

        def drop_rate_from_events(state, events)
          rates = events.filter_map { |e| e.try(:adaptive_rate) || e[:adaptive_rate] }
          return if rates.empty?

          # The events occurred AT rates.min, so that rate was too high.
          # Drop one below to converge toward the actual server limit.
          state.drop_to_rate!(rates.min - 1)
        end

        # Push the encounter-based ceiling confidence into Redis so the
        # AdaptiveState dynamic ceiling threshold reflects learning decisions.
        #
        # Counts distinct 1-minute time windows that contain at least one
        # rate_limit-classified event, rather than raw event count.  This
        # prevents high-concurrency bursts (e.g. 100 threads all getting
        # a 429 in the same second) from inflating confidence and stalling
        # upward probing.
        def sync_ceiling_confidence(state, registry_name)
          timestamps = Storage::CapturedEvent
            .for_registry(registry_name)
            .rate_limit_signals
            .where(created_at: 24.hours.ago..)
            .pluck(:created_at)
          encounter_count = timestamps.map { |t| t.strftime("%Y-%m-%d %H:%M") }.uniq.size
          state.sync_ceiling_confidence!(encounter_count)
        end

        def authorize_ui!
          auth = Hanikamu::RateLimit.config.ui_auth

          if auth.nil?
            render plain: "Forbidden – ui_auth is not configured", status: :forbidden
            return
          end

          allowed = if auth.arity.zero?
                      instance_exec(&auth)
                    else
                      auth.call(self)
                    end

          return if allowed

          render plain: "Unauthorized", status: :unauthorized
        rescue StandardError
          render plain: "Unauthorized", status: :unauthorized
        end
      end
    end
  end
end
