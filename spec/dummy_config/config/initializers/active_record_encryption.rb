# frozen_string_literal: true

# ActiveRecord::Encryption keys for the dummy/demo app only.
# Real applications should use `rails credentials:edit` or ENV vars.
Rails.application.config.active_record.encryption.primary_key = "dummy-primary-key-for-dev-only-32b"
Rails.application.config.active_record.encryption.deterministic_key = "dummy-deterministic-key-dev-32bb"
Rails.application.config.active_record.encryption.key_derivation_salt = "dummy-key-derivation-salt-dev0000"
