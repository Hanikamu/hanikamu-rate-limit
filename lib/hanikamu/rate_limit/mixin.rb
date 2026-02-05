# frozen_string_literal: true

module Hanikamu
  module RateLimit
    module Mixin
      def limit_method(method, rate:, interval: 60, **options, &)
        queue = build_queue(rate, interval, method, options, &)
        install_rate_limited_method(method, queue)
      end

      def limit_with(method, registry:, **overrides, &)
        registry_config = Hanikamu::RateLimit.fetch_limit(registry)
        merged = registry_config.merge(overrides.compact)
        rate = merged.fetch(:rate)
        interval = merged.fetch(:interval)
        options = merged.slice(:check_interval, :max_wait_time, :key_prefix, :headers)
        queue = build_queue(rate, interval, method, options, &)
        install_rate_limited_method(method, queue)
      end

      private

      def build_queue(rate, interval, method, options, &)
        Hanikamu::RateLimit::RateQueue.new(
          rate,
          interval: interval,
          klass_name: name,
          method: method,
          key_prefix: options[:key_prefix],
          check_interval: options.fetch(:check_interval, Hanikamu::RateLimit.config.check_interval),
          max_wait_time: options.fetch(:max_wait_time, Hanikamu::RateLimit.config.max_wait_time),
          &
        )
      end

      def install_rate_limited_method(method, queue)
        mixin = Module.new do
          rate_queue = queue

          define_method(method) do |*args, **options, &blk|
            rate_queue.shift
            result = options.empty? ? super(*args, &blk) : super(*args, **options, &blk)
            rate_queue.record(result)
            result
          end
        end

        define_singleton_method("reset_#{method}_limit!") { queue.reset }
        prepend(mixin)
      end
    end
  end
end
