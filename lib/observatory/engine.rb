# frozen_string_literal: true

require "observatory/current"
require "observatory/trace"
require "observatory/sampling/decision"
require "observatory/serializer"
require "observatory/log_sink"
require "observatory/pipeline"
require "observatory/probes/puma"
require "observatory/probes/database"
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
  end
end
