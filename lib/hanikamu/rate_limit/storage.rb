# frozen_string_literal: true

module Hanikamu
  module RateLimit
    # ActiveRecord-backed persistence for adaptive rate-limit learning.
    #
    # Two tables:
    #   - hanikamu_rate_limit_events  — captured exceptions / HTTP responses
    #   - hanikamu_rate_limit_snapshots — periodic current_rate recordings
    #
    # All sensitive data (exception messages, headers) is encrypted at rest
    # via ActiveRecord::Encryption.
    #
    # Note: This storage layer is only available when ActiveRecord is present
    # in the host application. The gem does not declare ActiveRecord as a hard
    # dependency; include it yourself if you intend to use Storage-backed
    # adaptive rate-limit learning.
    module Storage
      autoload :CapturedEvent,  "hanikamu/rate_limit/storage/captured_event"
      autoload :RateSnapshot,   "hanikamu/rate_limit/storage/rate_snapshot"
      autoload :EventCapture,   "hanikamu/rate_limit/storage/event_capture"
      autoload :SnapshotRecorder, "hanikamu/rate_limit/storage/snapshot_recorder"
      autoload :RetentionCleanup, "hanikamu/rate_limit/storage/retention_cleanup"
    end
  end
end
