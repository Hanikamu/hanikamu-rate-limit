# frozen_string_literal: true

module Hanikamu
  module RateLimit
    module Mixin
      def limit_method(
        method,
        registry: nil,
        rate: nil,
        interval: nil,
        check_interval: nil,
        max_wait_time: nil,
        &
      )
        if registry
          validate_registry_only!(rate, interval, check_interval, max_wait_time)
          queue = build_queue_from_registry(method, registry, &)
        else
          validate_inline_options!(rate, interval)
          interval ||= 60
          queue = build_queue(
            rate,
            interval,
            method,
            check_interval: check_interval,
            max_wait_time: max_wait_time,
            &
          )
        end

        install_rate_limited_method(method, queue)
      end

      private

      def build_queue(
        rate,
        interval,
        method,
        key_prefix: nil,
        check_interval: nil,
        max_wait_time: nil,
        override_key: nil,
        &
      )
        Hanikamu::RateLimit::RateQueue.new(
          rate,
          interval: interval,
          klass_name: name,
          method: method,
          key_prefix: key_prefix,
          override_key: override_key,
          check_interval: check_interval.nil? ? Hanikamu::RateLimit.config.check_interval : check_interval,
          max_wait_time: max_wait_time.nil? ? Hanikamu::RateLimit.config.max_wait_time : max_wait_time,
          &
        )
      end

      def build_queue_from_registry(method, registry, &)
        registry_config = Hanikamu::RateLimit.fetch_limit(registry)
        rate = registry_config.fetch(:rate)
        interval = registry_config.fetch(:interval)
        build_queue(
          rate,
          interval,
          method,
          key_prefix: registry_config[:key_prefix],
          check_interval: registry_config[:check_interval],
          max_wait_time: registry_config[:max_wait_time],
          override_key: Hanikamu::RateLimit.override_key_for(registry),
          &
        )
      end

      def validate_registry_only!(rate, interval, check_interval, max_wait_time)
        return unless rate || interval || !check_interval.nil? || !max_wait_time.nil?

        raise ArgumentError, "registry: must be used alone"
      end

      def validate_inline_options!(rate, _interval)
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
