# frozen_string_literal: true

require "action_controller/railtie"
require "active_support/inflector"
require "active_support/dependencies"

module Hanikamu
  module RateLimit
    module UI
      class Engine < ::Rails::Engine
        isolate_namespace Hanikamu::RateLimit::UI
        config.root = File.expand_path(__dir__)
        controllers_path = File.expand_path("app/controllers", __dir__)
        views_path = File.expand_path("app/views", __dir__)

        config.paths.add "app/controllers", with: controllers_path
        config.paths.add "app/views", with: views_path
        config.paths.add "config/routes", with: File.expand_path("config/routes.rb", __dir__)
        config.autoload_paths << controllers_path
        config.eager_load_paths << controllers_path

        ActiveSupport::Inflector.inflections(:en) do |inflect|
          inflect.acronym "UI"
        end

        initializer "hanikamu.rate_limit.ui.autoload", before: :set_autoload_paths do |app|
          app.config.autoload_paths << controllers_path
          app.config.eager_load_paths << controllers_path
        end

        initializer "hanikamu.rate_limit.ui.load_controller" do
          require_dependency File.expand_path(
            "app/controllers/hanikamu/rate_limit/ui/dashboard_controller",
            __dir__
          )
          require_dependency File.expand_path(
            "app/controllers/hanikamu/rate_limit/ui/learning_controller",
            __dir__
          )
        end
      end
    end
  end
end
