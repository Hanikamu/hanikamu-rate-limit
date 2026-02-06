# frozen_string_literal: true

require "dry/configurable"
require "dry/container"
require "hanikamu/rate_limit/errors"
require "hanikamu/rate_limit/headers"
require "hanikamu/rate_limit/mixin"
require "hanikamu/rate_limit/rate_queue"
require "hanikamu/rate_limit/version"
require "hanikamu/rate_limit/engine" if defined?(Rails)

module Hanikamu
  module RateLimit
    extend Dry::Configurable

    setting :redis_url
    setting :max_wait_time, default: 2.0
    setting :check_interval, default: 0.5
    setting :rate_limit_headers
    setting :observations_key_prefix, default: "hanikamu:rate_limit:observed"
    setting :rate_limits_basic_auth

    class << self
      def configure(&block)
        super do |config|
          config.define_singleton_method(:register_limit) do |name, **options|
            Hanikamu::RateLimit.register_limit(name, **options)
          end
          block&.call(config)
        end
      end

      def register_limit(name, **options)
        registry.register(normalize_name(name), normalize_registry_options(name, options))
      end

      def fetch_limit(name)
        registry.resolve(normalize_name(name))
      rescue Dry::Container::Error
        raise ArgumentError, "Unknown registered limit: #{name}"
      end

      def reset_registry!
        @registry = Dry::Container.new
      end

      def registry
        @registry ||= Dry::Container.new
      end

      private

      def normalize_name(name)
        name.to_sym
      end

      def normalize_registry_options(name, options)
        rate = options.fetch(:rate)
        interval = options.fetch(:interval)
        key_prefix = options[:key_prefix] || "#{RateQueue::KEY_PREFIX}:registry:#{name}"
        registry_options = { rate: rate, interval: interval, key_prefix: key_prefix }
        registry_options[:check_interval] = options[:check_interval] unless options[:check_interval].nil?
        registry_options[:max_wait_time] = options[:max_wait_time] unless options[:max_wait_time].nil?
        registry_options[:headers] = options[:headers] unless options[:headers].nil?
        registry_options
      end
    end
  end
end
