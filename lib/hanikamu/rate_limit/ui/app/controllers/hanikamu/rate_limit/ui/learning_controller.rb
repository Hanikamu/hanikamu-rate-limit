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
          sync_ceiling_confidence(params[:registry])
          redirect_to learning_url(registry: params[:registry], filter: params[:filter])
        end

        # POST /learning/classify_batch
        def classify_batch
          ids = Array(params[:event_ids]).map(&:to_i)
          classification = params[:classification]

          unless Storage::CapturedEvent::CLASSIFICATIONS.include?(classification)
            return render(plain: "Invalid classification", status: :unprocessable_entity)
          end

          Storage::CapturedEvent.where(id: ids).update_all(classification: classification)
          sync_ceiling_confidence(params[:registry])
          redirect_to learning_url(registry: params[:registry], filter: params[:filter])
        end

        # POST /learning/classify_group
        def classify_group
          classification = params[:classification]

          unless Storage::CapturedEvent::CLASSIFICATIONS.include?(classification)
            return render(plain: "Invalid classification", status: :unprocessable_entity)
          end

          build_group_scope.update_all(classification: classification)
          sync_ceiling_confidence(params[:registry])
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

        # Push the current rate_limit-classified event count into Redis so
        # the AdaptiveState dynamic ceiling threshold reflects learning decisions.
        def sync_ceiling_confidence(registry_name)
          return if registry_name.blank?

          state = Hanikamu::RateLimit.fetch_adaptive_state(registry_name)
          count = Storage::CapturedEvent
            .for_registry(registry_name)
            .rate_limit_signals
            .where(created_at: 24.hours.ago..)
            .count
          state.sync_ceiling_confidence!(count)
        rescue ArgumentError
          # Not an adaptive limit — nothing to sync.
          nil
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
