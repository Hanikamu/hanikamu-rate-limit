# frozen_string_literal: true

Hanikamu::RateLimit::UI::Engine.routes.draw do
  root to: "dashboard#index"
  get "metrics", to: "dashboard#metrics"
  get "stream", to: "dashboard#stream"

  # Learning UI — event review & classification
  get    "learning", to: "learning#index"
  patch  "learning/:id/classify",   to: "learning#classify", as: :classify_event
  post   "learning/classify_batch", to: "learning#classify_batch", as: :classify_batch
  post   "learning/classify_group", to: "learning#classify_group", as: :classify_group
  delete "learning/purge",          to: "learning#purge", as: :purge_events
end
