# frozen_string_literal: true

Rails.application.routes.draw do
  require "hanikamu/rate_limit/ui"

  mount Hanikamu::RateLimit::UI::Engine => "/rate-limits"

  get "api/data" => "api#data"

  get "up" => "rails/health#show", as: :rails_health_check
end
