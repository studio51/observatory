# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

require "observatory"

module Dummy

  # The smallest Rails application Observatory can be mounted into.
  #
  # It exists so the engine's tests exercise a real boot — middleware insertion,
  # subscriber installation, migrations, routes and the dashboard — rather than a
  # hand-assembled approximation of one. Nothing here is Observatory-specific
  # beyond mounting it; a host application that looked like this would work.
  #
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    config.root = File.expand_path("..", __dir__)

    config.eager_load = false

    config.secret_key_base = "observatory-dummy-application-secret-key-base"
  end
end
