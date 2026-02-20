# frozen_string_literal: true

require "active_record"

module Hanikamu
  module RateLimit
    module Storage
      # Stores a captured exception or HTTP response for the learning UI.
      # Users review these events and classify them as rate-limit signals or noise.
      #
      # Encrypted columns: exception_message, response_headers, response_body_snippet.
      # Requires ActiveRecord::Encryption to be configured in the host app
      # (rails credentials:edit to add active_record_encryption keys).
      class CapturedEvent < ActiveRecord::Base
        self.table_name = "hanikamu_rate_limit_events"

        encrypts :exception_message, :response_headers, :response_body_snippet

        # Classification statuses
        UNCLASSIFIED = "unclassified"
        RATE_LIMIT   = "rate_limit"
        IGNORED      = "ignored"

        CLASSIFICATIONS = [UNCLASSIFIED, RATE_LIMIT, IGNORED].freeze

        validates :registry_name, presence: true
        validates :event_type, inclusion: { in: %w[exception response] }
        validates :classification, inclusion: { in: CLASSIFICATIONS }

        scope :unclassified, -> { where(classification: UNCLASSIFIED) }
        scope :rate_limit_signals, -> { where(classification: RATE_LIMIT) }
        scope :ignored, -> { where(classification: IGNORED) }
        scope :for_registry, ->(name) { where(registry_name: name.to_s) }
        scope :recent, -> { order(created_at: :desc) }
      end
    end
  end
end
