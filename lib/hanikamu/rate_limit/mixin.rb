# frozen_string_literal: true

module Hanikamu
  module RateLimit
    module Mixin
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
