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
      # install path; adaptive limits wire up the AIMD wrapper.
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
      # an error-handling module on top for AIMD error_classes.
      # Also injects a report_rate_limit_headers instance helper.
      def install_adaptive_rate_limited_method(method, queue, state, cfg, reg_name)
        prepend(build_adaptive_mixin(method, queue, state, cfg, reg_name))
        prepend(build_error_handling_mixin(method, state, cfg, reg_name)) if Array(cfg[:error_classes]).any?
        prepend(build_report_headers_helper)

        define_singleton_method("reset_#{method}_limit!") do
          queue.reset
          state.reset!
        end
      end

      def build_adaptive_mixin(method, queue, state, cfg, reg_name)
        resp_parser = cfg[:response_parser]
        Module.new do
          define_method(method) do |*args, **options, &blk|
            queue.shift
            result = options.empty? ? super(*args, &blk) : super(*args, **options, &blk)
            decreased = Hanikamu::RateLimit::Mixin.send(:apply_response_parser, resp_parser, result, state,
                                                        reg_name)
            state.record_success! unless decreased
            result
          end
        end
      end

      # Runs the response_parser and applies AIMD / capture side-effects.
      # Returns true when the parser signalled a rate decrease.
      private_class_method def self.apply_response_parser(parser, result, state, reg_name)
        return false unless parser

        parsed = parser.call(result)
        return false unless parsed.is_a?(Hash)

        apply_temporary_limit(reg_name, parsed)

        decreased = parsed[:decrease] == true
        rate_before = state.current_rate
        state.decrease_rate! if decreased
        Hanikamu::RateLimit::Storage::EventCapture.capture_response(reg_name, result, parsed,
                                                                    adaptive_rate: rate_before)
        decreased
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

      def build_error_handling_mixin(method, state, cfg, reg_name)
        errors = cfg[:error_classes]
        parser = cfg[:header_parser]
        Module.new do
          define_method(method) do |*args, **options, &blk|
            options.empty? ? super(*args, &blk) : super(*args, **options, &blk)
          rescue *errors => e
            rate_before = state.current_rate
            state.handle_error(e, reg_name, parser)
            Hanikamu::RateLimit::Storage::EventCapture.capture_exception(reg_name, e,
                                                                         adaptive_rate: rate_before)
            raise
          end
        end
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
    end
  end
end
