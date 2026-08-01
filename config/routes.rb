# frozen_string_literal: true

Observatory::Engine.routes.draw do
  root to: "dashboards#show"

  resources :incidents, only: [ :index, :show ] do
    collection { post :analyse }
    member { patch :resolve }
  end

  resources :requests, only: [ :index, :show ]
  resources :jobs, only: [ :index, :show ]
  resources :routes, only: [ :index ]

  # A route template contains slashes and colons ("/steam/achievements/:id"), so
  # it cannot be a path segment without escaping that nobody would enjoy reading
  # in a URL. The endpoint travels as a query parameter instead.
  get "route", to: "routes#show", as: :route
end
