# frozen_string_literal: true

require "redis"
require "json"

module Hanikamu
  module RateLimit
    class RateLimitsController < ActionController::Base
      before_action :authenticate_rate_limits

      def index
        prefix = Hanikamu::RateLimit.config.observations_key_prefix
        redis_client = Redis.new(url: Hanikamu::RateLimit.config.redis_url)
        keys = redis_client.smembers("#{prefix}:keys")
        limits = keys.each_with_object({}) do |key, acc|
          data = redis_client.hgetall(key)
          redis_key = data["redis_key"] || key
          acc[redis_key] = build_limit_payload(data)
        end

        render json: { rate_limits: limits }
      end

      private

      def authenticate_rate_limits
        credentials = Hanikamu::RateLimit.config.rate_limits_basic_auth
        return unless credentials

        username = credentials[:username] || credentials["username"]
        password = credentials[:password] || credentials["password"]
        return if username.nil? || password.nil?

        authenticate_or_request_with_http_basic("Rate Limits") do |user, pass|
          ActiveSupport::SecurityUtils.secure_compare(user.to_s, username.to_s) &&
            ActiveSupport::SecurityUtils.secure_compare(pass.to_s, password.to_s)
        end
      end

        def build_limit_payload(data)
          config_keys = %w[
            rate interval klass_name method key_prefix redis_key check_interval max_wait_time headers_config observed_at
          ]

          configuration = data.slice(*config_keys)
          headers_config = configuration["headers_config"]
          if headers_config && !headers_config.empty?
            configuration["headers_config"] = parse_headers_config(headers_config)
          end

          headers = data.reject { |key, _| config_keys.include?(key) }

          {
            configuration: configuration,
            headers: headers
          }
        end

        def parse_headers_config(value)
          JSON.parse(value)
        rescue JSON::ParserError
          value
        end
    end
  end
end
