# frozen_string_literal: true

Rails.application.routes.draw do
  root to: "home#index"

  resources :users, only: [ :show ]

  # `/up` is in Observatory's default `health_check_paths`, and `/assets/…` in
  # its default `ignored_paths`. Both are asserted by the tracing tests, so the
  # dummy application has to offer the same surface a real one does.
  #
  get "up" => "rails/health#show", as: :rails_health_check

  get "errors/internal_server_error" => "errors#internal_server_error"

  mount(Observatory::Engine, at: "/observatory", as: :observatory)
end
