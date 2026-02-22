# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module HanikamuRateLimit
  module Generators
    # Rails generator that creates the migrations for the rate-limit
    # storage tables (captured events and rate snapshots).
    #
    #   rails generate hanikamu_rate_limit:install
    #
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Creates migrations for hanikamu-rate-limit storage tables."

      def create_events_migration
        migration_template(
          "create_hanikamu_rate_limit_events.rb.erb",
          "db/migrate/create_hanikamu_rate_limit_events.rb"
        )
      end

      def create_snapshots_migration
        sleep 1 # ensure distinct timestamp for second migration
        migration_template(
          "create_hanikamu_rate_limit_snapshots.rb.erb",
          "db/migrate/create_hanikamu_rate_limit_snapshots.rb"
        )
      end
    end
  end
end
