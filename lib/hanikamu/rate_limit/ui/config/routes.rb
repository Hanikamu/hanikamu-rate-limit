# frozen_string_literal: true

Hanikamu::RateLimit::UI::Engine.routes.draw do
  root to: "dashboard#index"
  get "metrics", to: "dashboard#metrics"
  get "stream", to: "dashboard#stream"
end
