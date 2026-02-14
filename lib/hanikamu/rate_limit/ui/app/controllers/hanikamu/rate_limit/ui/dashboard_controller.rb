# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"

module Hanikamu
  module RateLimit
    module UI
      class DashboardController < ActionController::Base
        include ActionController::Live

        layout false
        before_action :authorize_ui!

        def index
          @payload = Hanikamu::RateLimit::Metrics.dashboard_payload
        end

        def metrics
          render json: Hanikamu::RateLimit::Metrics.dashboard_payload
        end

        SSE_INTERVAL = 2
        SSE_TIMEOUT = 300 # disconnect after 5 minutes, client will auto-reconnect

        @sse_connections = Concurrent::AtomicFixnum.new(0)

        class << self
          attr_reader :sse_connections
        end

        def stream
          return reject_sse_overflow if sse_connections_full?

          self.class.sse_connections.increment
          begin
            stream_sse_loop
          ensure
            self.class.sse_connections.decrement
          end
        end

        private

        def sse_connections_full?
          max = Hanikamu::RateLimit.config.ui_max_sse_connections
          max && self.class.sse_connections.value >= max
        end

        def reject_sse_overflow
          render plain: "Too many SSE connections", status: :service_unavailable
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
          sse.write(Hanikamu::RateLimit::Metrics.dashboard_payload, event: "metrics")
        rescue StandardError => e
          Rails.logger.error("[HanikamuRateLimit::UI] SSE payload error: #{e.class}: #{e.message}")
          sse.write({ error: e.message }, event: "error")
        end

        def configure_sse_headers
          response.headers["Content-Type"] = "text/event-stream"
          response.headers["Cache-Control"] = "no-cache"
          response.headers["X-Accel-Buffering"] = "no"
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
