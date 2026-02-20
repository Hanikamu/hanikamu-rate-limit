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
          queue = build_queue_from_registry(method, registry, &)
        else
          validate_inline_options!(rate, interval)
          queue = build_queue(rate, interval || 60, method,
                              check_interval: check_interval, max_wait_time: max_wait_time,
                              metrics: metrics, &)
        end

        install_rate_limited_method(method, queue)
      end

      private

      def build_queue(rate, interval, method, key_prefix: nil, check_interval: nil,
                      max_wait_time: nil, override_key: nil, metrics: nil, &)
        Hanikamu::RateLimit::RateQueue.new(
          rate, interval: interval, klass_name: name, method: method,
                key_prefix: key_prefix, override_key: override_key,
                check_interval: check_interval,
                max_wait_time: max_wait_time,
                metrics: metrics, &
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
    end
  end
end
