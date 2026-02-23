# frozen_string_literal: true

module Hanikamu
  module RateLimit
    # DSL module included into classes that need rate-limited methods.
    #
    # Usage:  `extend Hanikamu::RateLimit::Mixin` then call `limit_method`.
    #
    # How it works:
    #   1. Creates a RateQueue with the given (or registry-looked-up) config.
    #   2. Builds an anonymous Module that overrides the target method to call
    #      `rate_queue.shift` before delegating to `super`.
    #   3. Prepends that module into the class, so the rate-limit wrapper runs
    #      first while the original method body is untouched.
    #   4. Defines a `reset_<method>_limit!` singleton method for manual reset.
    module Mixin
      # @param method [Symbol] the instance method to wrap
      # @param registry [Symbol, nil] name of a registered limit (mutually exclusive with inline opts)
      # @param rate [Integer, nil] max requests per interval
      # @param interval [Numeric, nil] window size in seconds (default 60)
      def limit_method(method, registry: nil, rate: nil, interval: nil,
                       check_interval: nil, max_wait_time: nil, metrics: nil, &)
        if registry
          validate_registry_only!(rate, interval, check_interval, max_wait_time, metrics)
          build_and_install_registry_limit(method, registry, &)
        else
          validate_inline_options!(rate, interval)
          queue = build_queue(rate, interval || 60, method,
                              check_interval: check_interval, max_wait_time: max_wait_time,
                              metrics: metrics, &)
          install_rate_limited_method(method, queue)
        end
      end

      private

      def build_queue(rate, interval, method, key_prefix: nil, check_interval: nil,
                      max_wait_time: nil, override_key: nil, metrics: nil,
                      adaptive_state: nil, &)
        Hanikamu::RateLimit::RateQueue.new(
          rate, interval: interval, klass_name: name, method: method,
                key_prefix: key_prefix, override_key: override_key,
                check_interval: check_interval,
                max_wait_time: max_wait_time,
                metrics: metrics, adaptive_state: adaptive_state, &
        )
      end

      # Looks up the named limit from the registry and builds a RateQueue.
      # Also resolves the override_key so temporary limits (via register_temporary_limit)
      # are automatically wired into the queue's Lua script.
      def build_queue_from_registry(method, registry, &)
        cfg = Hanikamu::RateLimit.fetch_limit(registry)
        build_queue(
          cfg.fetch(:rate), cfg.fetch(:interval), method,
          key_prefix: cfg[:key_prefix], check_interval: cfg[:check_interval],
          max_wait_time: cfg[:max_wait_time],
          override_key: Hanikamu::RateLimit.override_key_for(registry),
          metrics: cfg[:metrics], &
        )
      end

      # Fetches the registry config and branches: fixed limits use the existing
      # install path; adaptive limits wire up the adaptive wrapper.
      def build_and_install_registry_limit(method, registry, &)
        cfg = Hanikamu::RateLimit.fetch_limit(registry)
        if cfg[:adaptive]
          build_and_install_adaptive_limit(method, registry, cfg, &)
        else
          queue = build_queue_from_registry(method, registry, &)
          install_rate_limited_method(method, queue)
        end
      end

      def build_and_install_adaptive_limit(method, registry, cfg, &)
        state = Hanikamu::RateLimit.fetch_adaptive_state(registry)
        queue = build_queue(
          cfg.fetch(:rate), cfg.fetch(:interval), method,
          key_prefix: cfg[:key_prefix], check_interval: cfg[:check_interval],
          max_wait_time: cfg[:max_wait_time],
          override_key: Hanikamu::RateLimit.override_key_for(registry),
          metrics: cfg[:metrics], adaptive_state: state, &
        )
        state.attach_sliding_window(queue.sliding_window_key, queue.interval)
        install_adaptive_rate_limited_method(method, queue, state, cfg, registry)
      end

      def validate_registry_only!(rate, interval, check_interval, max_wait_time, metrics)
        return unless rate || interval || !check_interval.nil? || !max_wait_time.nil? || !metrics.nil?

        raise ArgumentError, "registry: must be used alone"
      end

      def validate_inline_options!(rate, _interval = nil)
        return if rate

        raise ArgumentError, "Either registry: or rate: must be provided"
      end

      # Builds an anonymous Module with a single method override and prepends it.
      # Using prepend (not alias_method) keeps the original method body in the
      # inheritance chain — `super` calls it cleanly with no naming conflicts.
      def install_rate_limited_method(method, queue)
        mixin = Module.new do
          rate_queue = queue

          define_method(method) do |*args, **options, &blk|
            rate_queue.shift
            options.empty? ? super(*args, &blk) : super(*args, **options, &blk)
          end
        end

        define_singleton_method("reset_#{method}_limit!") { queue.reset }
        prepend(mixin)
      end

      # Builds the rate-gate + record_success module, optionally layering
      # an error-capture module on top for error_classes.
      # Also injects report_rate_limit_headers and hanikamu_adaptive_feedback helpers.
      def install_adaptive_rate_limited_method(method, queue, state, cfg, reg_name)
        prepend(build_adaptive_mixin(method, queue, state, cfg, reg_name))
        prepend(build_error_capture_mixin(method, cfg, reg_name, state)) if Array(cfg[:error_classes]).any?
        prepend(build_report_headers_helper)
        prepend(build_adaptive_feedback_helper)

        define_singleton_method("reset_#{method}_limit!") do
          queue.reset
          state.reset!
        end
      end

      def build_adaptive_mixin(method, queue, state, cfg, reg_name)
        resp_parser = cfg[:response_parser]
        method_name = method
        registry_name = reg_name
        Module.new do
          define_method(method_name) do |*args, **options, &blk|
            queue.shift
            # Snapshot the rate that was in effect when this request was admitted.
            # Concurrent threads that entered at the same rate will all use this
            # value for drop calculations, preventing cascading drops.
            call_rate = state.current_rate
            result = options.empty? ? super(*args, &blk) : super(*args, **options, &blk)

            # Prefer explicit feedback from hanikamu_adaptive_feedback over the return value.
            feedback_key = [method_name, registry_name]
            feedback = Thread.current[:hanikamu_adaptive_feedback]&.delete(feedback_key)
            response_data = feedback || result

            captured = Hanikamu::RateLimit::Mixin.send(:store_response_event, resp_parser, response_data,
                                                       state, registry_name, call_rate)
            state.record_success! unless captured
            result
          end
        end
      end

      # When an event inherits "rate_limit" classification, immediately
      # drop the adaptive rate one below the rate that caused the error.
      # This makes the system self-correcting once the user teaches it
      # which events are true rate-limit signals.
      #
      # No-ops when `event` is nil (capture failed) or unclassified
      # (no prior sibling has been labelled "rate_limit" yet).
      private_class_method def self.auto_drop_if_rate_limit(state, event, captured_rate)
        return unless event.respond_to?(:classification) && event.classification == "rate_limit"

        state.drop_to_rate!(captured_rate - 1)
      end

      # Runs the response_parser and captures the event if the parser returns
      # a non-nil Hash.  Uses the call_rate (captured at admission time) so
      # concurrent 429s from the same burst all drop to the same value.
      # Returns true when an event was captured, false otherwise.
      private_class_method def self.store_response_event(parser, result, state, reg_name, call_rate) # rubocop:disable Naming/PredicateMethod
        return false unless parser

        parsed = parser.call(result)
        return false unless parsed.is_a?(Hash)

        apply_temporary_limit(reg_name, parsed)

        event = Hanikamu::RateLimit::Storage::EventCapture.capture_response(reg_name, result, parsed,
                                                                            adaptive_rate: call_rate)
        # When a user has classified a previous event of this type as
        # "rate_limit" in the Learning UI, inherit_classification copies
        # the label onto the new event.  auto_drop fires in that case,
        # making the system self-correcting once event types are taught.
        # First-time (unclassified) events are no-ops here.
        auto_drop_if_rate_limit(state, event, call_rate)
        true
      end

      private_class_method def self.apply_temporary_limit(reg_name, parsed)
        return unless parsed[:remaining]

        Hanikamu::RateLimit.register_temporary_limit(
          reg_name,
          remaining: parsed[:remaining],
          reset: parsed[:reset],
          reset_kind: parsed[:reset_kind] || :seconds
        )
      end

      # Captures exceptions from error_classes into the Learning UI.
      # If a header_parser is configured, also extracts rate-limit headers
      # and registers a temporary limit (sliding window override).
      # The exception still raises — no automatic rate decrease.
      def build_error_capture_mixin(method, cfg, reg_name, state)
        errors = cfg[:error_classes]
        h_parser = cfg[:header_parser]
        adaptive_state = state
        Module.new do
          define_method(method) do |*args, **options, &blk|
            # Snapshot rate at call-time so concurrent errors from the same
            # burst all use the same rate for drop calculations.
            call_rate = adaptive_state.current_rate
            options.empty? ? super(*args, &blk) : super(*args, **options, &blk)
          rescue *errors => e
            Hanikamu::RateLimit::Mixin.send(:apply_header_parser, h_parser, e, reg_name)
            event = Hanikamu::RateLimit::Storage::EventCapture.capture_exception(reg_name, e,
                                                                                 adaptive_rate: call_rate)
            # See store_response_event — fires only for inherited classifications.
            Hanikamu::RateLimit::Mixin.send(:auto_drop_if_rate_limit, adaptive_state, event, call_rate)
            raise
          end
        end
      end

      private_class_method def self.apply_header_parser(parser, error, reg_name)
        return unless parser

        parsed = parser.call(error)
        return unless parsed.is_a?(Hash) && parsed[:remaining]

        Hanikamu::RateLimit.register_temporary_limit(
          reg_name,
          remaining: parsed[:remaining],
          reset: parsed[:reset]
        )
      end

      # Injects a report_rate_limit_headers instance method so users can
      # manually feed rate-limit data back to the adaptive state.
      def build_report_headers_helper
        Module.new do
          def report_rate_limit_headers(registry_name, remaining:, reset:, reset_kind: :seconds)
            Hanikamu::RateLimit.register_temporary_limit(
              registry_name, remaining: remaining, reset: reset, reset_kind: reset_kind
            )
          end
        end
      end

      # Injects hanikamu_adaptive_feedback so users can pass response data
      # to the adaptive rate limiter without coupling their method's
      # return value.  The wrapper picks this up after the method
      # returns and feeds it to the response_parser instead.
      def build_adaptive_feedback_helper
        Module.new do
          def hanikamu_adaptive_feedback(method_name, registry:, **response_data)
            Thread.current[:hanikamu_adaptive_feedback] ||= {}
            Thread.current[:hanikamu_adaptive_feedback][[method_name, registry]] = response_data
          end
        end
      end
    end
  end
end
