# frozen_string_literal: true

require "date"

module Hanikamu
  module RateLimit
    # Converts the `reset` value supplied to `register_temporary_limit` into a
    # Redis TTL in seconds, based on the chosen `reset_kind`.
    #
    # Three strategies:
    #   :seconds  — value is already seconds (e.g. Retry-After: 30). Guarded by
    #               MAX_SECONDS_TTL (86 400 = 24 h) to catch accidentally passing
    #               a Unix timestamp in seconds mode.
    #   :unix     — value is a Unix epoch timestamp (e.g. X-RateLimit-Reset: 1718450000).
    #               Converted via `timestamp - Time.now.to_i`.
    #   :datetime — value is a Time or DateTime object. Converted to epoch via
    #               `.to_time.to_i - Time.now.to_i`. Rejects other types to avoid
    #               silent coercion bugs (Array(Time.now) calls Time#to_a, not wrap).
    #
    # All paths produce UTC-safe output because they reduce to epoch arithmetic.
    module ResetTtlResolver
      VALID_RESET_KINDS = %i[seconds unix datetime].freeze

      # 24 hours — any :seconds value above this is almost certainly a Unix timestamp
      # passed with the wrong reset_kind.
      MAX_SECONDS_TTL = 86_400

      module_function

      # Entry point. Dispatches to the appropriate resolver based on reset_kind.
      # Returns an Integer (seconds) or nil if the value cannot be parsed.
      def resolve(reset, reset_kind)
        validate_reset_kind!(reset_kind)

        case reset_kind
        when :seconds then resolve_seconds(reset)
        when :unix then resolve_unix(reset)
        when :datetime then resolve_datetime(reset)
        end
      end

      def validate_reset_kind!(reset_kind)
        return if VALID_RESET_KINDS.include?(reset_kind)

        raise ArgumentError,
              "Invalid reset_kind: #{reset_kind.inspect}. Must be one of #{VALID_RESET_KINDS.join(", ")}"
      end

      # Array() unwraps single-element arrays (common in HTTP header parsing)
      # and Integer(..., exception: false) returns nil for non-numeric strings.
      def resolve_seconds(reset)
        ttl = Integer(Array(reset).first, exception: false)
        return ttl if ttl.nil? || ttl <= MAX_SECONDS_TTL

        raise ArgumentError,
              "reset value #{ttl} exceeds MAX_SECONDS_TTL (#{MAX_SECONDS_TTL}). " \
              "Use reset_kind: :unix for Unix timestamps"
      end

      # Subtracts current epoch time to get a forward-looking TTL.
      # Returns nil (no override) if the header value is non-numeric.
      def resolve_unix(reset)
        unix_ts = Integer(Array(reset).first, exception: false)
        unix_ts && (unix_ts - Time.now.to_i)
      end

      # Only accepts Time and DateTime — not String or Integer — because
      # Array(time_obj) calls Time#to_a (returns [sec,min,hour,...]) instead
      # of wrapping, which would silently produce garbage.
      def resolve_datetime(reset)
        return nil unless reset.is_a?(Time) || reset.is_a?(DateTime)

        reset.to_time.to_i - Time.now.to_i
      end
    end
  end
end
