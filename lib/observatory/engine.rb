# frozen_string_literal: true

require "observatory/current"
require "observatory/trace"
require "observatory/sampling/decision"
require "observatory/serializer"
require "observatory/log_sink"
require "observatory/pipeline"
require "observatory/probes/puma"
require "observatory/probes/database"
require "observatory/probes/redis"
require "observatory/probes/sidekiq"
require "observatory/probes/process"
require "observatory/retention"
require "observatory/sampler"
require "observatory/analysis/rules/cached_query_explosion"
require "observatory/analysis/rules/executed_query_explosion"
require "observatory/analysis/rules/slow_sql"
require "observatory/analysis/rules/puma_saturation"
require "observatory/analysis/rules/health_check_blocked"
require "observatory/analysis/rules/watchdog_misclassification"
require "observatory/analysis/rules/database_pool_starvation"
require "observatory/analysis/rules/gc_pressure"
require "observatory/analysis/rules/queue_drain_regression"
require "observatory/analysis/rules/healthy_backlog"
require "observatory/analysis/rules/redis_saturation"
require "observatory/analysis/rules/crawler_amplification"
require "observatory/analysis/rules/deployment_regression"
require "observatory/analysis/engine"
require "observatory/timeline"
require "observatory/watchdog"
require "observatory/runtime"
require "observatory/collectors/active_record"
require "observatory/collectors/action_controller"
require "observatory/collectors/cache"
require "observatory/middleware/request_tracker"

module Observatory

  # Mounts Observatory into a host Rails application.
  #
  # ## Installed always, active conditionally
  #
  # The middleware and the subscribers are installed unconditionally, and every
  # one of them asks `Observatory.enabled?` on entry. That is deliberate, and it
  # is not the same thing as being wasteful:
  #
  # - A Rack stack is assembled once at boot and frozen. Deciding middleware
  #   presence from a flag would make `enabled` a boot-time-only switch, when the
  #   whole value of an off switch is being able to reach for it *during* an
  #   incident, from a console, without a restart.
  # - The cost of a disabled subscriber is exact and tiny: when nothing is being
  #   measured, `Current.execution` is nil, so the busiest subscriber in the
  #   system returns after two hash reads and allocates nothing.
  # - It makes the disabled path a tested path rather than an untested one.
  #
  # ## Where the middleware goes, and why it matters
  #
  # Immediately after `ActionDispatch::RequestId`. Earlier and there would be no
  # request id to correlate with the application log; later and the time spent in
  # `Rack::Attack`, CORS, session loading and the router would go uncounted —
  # time which is nonetheless holding a Puma thread. A system built to explain
  # thread exhaustion has to measure the whole thread.
  #
  class Engine < ::Rails::Engine
    isolate_namespace Observatory

    config.observatory = Observatory.config

    # Environment overrides are applied before any initializer reads the
    # configuration, and again after the host's own `Observatory.configure` block
    # so the environment always has the last word.
    #
    config.before_initialize do
      Observatory.config.apply_environment_overrides!
    end

    initializer "observatory.middleware" do |app|
      app.config.middleware.insert_after(
        ActionDispatch::RequestId,
        Observatory::Middleware::RequestTracker,
      )
    end

    initializer "observatory.subscribers" do
      ActiveSupport.on_load(:active_record) { Observatory::Collectors::ActiveRecord.install! }

      Observatory::Collectors::ActionController.install!
      Observatory::Collectors::Cache.install!
    end

    initializer "observatory.external_http" do
      require "observatory/collectors/net_http"

      Observatory::Collectors::NetHttp.install!
    end

    initializer "observatory.sidekiq" do
      next unless defined?(::Sidekiq)

      require "observatory/sidekiq/middleware"

      Observatory::Sidekiq::Middleware.install!
    end

    # The engine owns its migrations. Adding them to the host's migration paths
    # rather than copying them in means `db:migrate` picks them up wherever the
    # engine lives, and an upgrade is a `bundle update` rather than a rake task
    # plus a diff review.
    #
    initializer "observatory.migrations" do |app|
      next if app.root.to_s == root.to_s

      config.paths["db/migrate"].expanded.each do |path|
        app.config.paths["db/migrate"] << path
      end
    end

    initializer "observatory.connection" do
      ActiveSupport.on_load(:active_record) do
        Observatory::Record.connect_to_configured_database!
      end
    end

    # Background threads start after boot, never during it. This application runs
    # Puma with `preload_app!`, so a thread created before the fork simply does
    # not exist in the workers — and does not say so. `on_worker_boot` in
    # `config/puma.rb` covers the clustered case; this covers everything else.
    #
    config.after_initialize do
      Observatory::Runtime.start!
    end

    rake_tasks do
      load File.expand_path("../tasks/observatory.rake", __dir__)
    end
  end
end
