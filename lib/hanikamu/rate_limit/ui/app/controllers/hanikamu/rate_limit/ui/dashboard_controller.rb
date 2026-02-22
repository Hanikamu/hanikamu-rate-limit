# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"
require "hanikamu/rate_limit/ui/presenters/dashboard_presenter"
require "hanikamu/rate_limit/ui/presenters/limit_presenter"

module Hanikamu
  module RateLimit
    module UI
      class DashboardController < ActionController::Base
        include ActionController::Live

        append_view_path File.expand_path("../../../../views", __dir__)
        layout false
        before_action :authorize_ui!
        helper_method :engine_root

        def index
          payload = Hanikamu::RateLimit::Metrics.dashboard_payload
          @presenter = DashboardPresenter.new(payload)
        end

        def metrics
          render json: Hanikamu::RateLimit::Metrics.dashboard_payload
        end

        SSE_INTERVAL = 2
        SSE_TIMEOUT = 60 # disconnect after 60 s; EventSource auto-reconnects

        @sse_connections = Concurrent::AtomicFixnum.new(0)

        class << self
          attr_reader :sse_connections
        end

        def stream
          return render plain: "Too many SSE connections", status: :service_unavailable unless acquire_sse_slot?

          begin
            stream_sse_loop
          ensure
            self.class.sse_connections.decrement
          end
        end

        private

        def acquire_sse_slot?
          max = Hanikamu::RateLimit.config.ui_max_sse_connections
          return true unless max

          count = self.class.sse_connections.increment
          return true if count <= max

          self.class.sse_connections.decrement
          false
        end

        def stream_sse_loop
          configure_sse_headers
          sse = SSE.new(response.stream)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          loop do
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            break if elapsed > SSE_TIMEOUT

            emit_payload(sse)
            sleep SSE_INTERVAL
          end
        rescue ActionController::Live::ClientDisconnected, IOError
          # Client closed the connection
        ensure
          sse.close if defined?(sse) && sse
        end

        def emit_payload(sse)
          tick_snapshot_recorder
          sse.write(Hanikamu::RateLimit::Metrics.dashboard_payload, event: "metrics")
        rescue StandardError => e
          Rails.logger.error("[HanikamuRateLimit::UI] SSE payload error: #{e.class}: #{e.message}")
          sse.write({ error: "internal_error" }, event: "error")
        end

        def configure_sse_headers
          response.headers["Content-Type"] = "text/event-stream"
          response.headers["Cache-Control"] = "no-cache"
          response.headers["X-Accel-Buffering"] = "no"
        end

        def tick_snapshot_recorder
          Hanikamu::RateLimit::Storage::SnapshotRecorder.tick!
        rescue StandardError => e
          Rails.logger.error("[HanikamuRateLimit::UI] Snapshot tick error: #{e.class}: #{e.message}")
        end

        # Base URL of the engine mount point, derived from the request path.
        def engine_root
          request.path.sub(%r{/(metrics|stream|learning)\b.*}, "")
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

        class SSE
          def initialize(stream)
            @stream = stream
          end

          def write(data, event: nil)
            @stream.write("event: #{event}\n") if event
            @stream.write("data: #{data.to_json}\n\n")
          end

          def close
            @stream.close
          rescue IOError
            nil
          end
        end
      end
    end
  end
end
