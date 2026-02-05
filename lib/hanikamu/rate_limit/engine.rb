# frozen_string_literal: true

require "rails/engine"
require "hanikamu/rate_limit/rate_limits_controller"

module Hanikamu
  module RateLimit
    class Engine < ::Rails::Engine
      isolate_namespace Hanikamu::RateLimit

      routes.draw do
        get "/rate_limits" => "rate_limits#index"
        get "/" => "rate_limits#index"
      end
    end
  end
end
