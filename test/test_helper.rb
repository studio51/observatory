# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"

# Build the schema by running the migrations rather than loading a checked-in
# dump. The engine contributes its own migration path to the host application
# (see `Observatory::Engine`), so this also asserts that the mechanism works: a
# migration the engine fails to hand over is a failing suite, not silent drift.
#
# This has to happen before `rails/test_help`, which checks for pending
# migrations as it loads.
#
# The paths are expanded explicitly because `ActiveRecord::Migrator` holds them
# relative ("db/migrate") and resolves them against the working directory — which
# is the gem root here, not the dummy application's. Left alone, the migrator
# reads the engine's own `db/migrate` and silently never sees the dummy's.
#
ActiveRecord::Migration.verbose = false
ActiveRecord::Migrator.migrations_paths = Rails.application.config.paths["db/migrate"].expanded

ActiveRecord::Tasks::DatabaseTasks.migrate

require "rails/test_help"
require_relative "support/observatory_helper"

class ActiveSupport::TestCase
  include ObservatoryHelper

  self.fixture_paths = [ File.expand_path("fixtures", __dir__) ]

  fixtures :all

  # Adapter detection is memoised for the life of the process, so a test that
  # runs against a stubbed connection must not leak that decision into the next.
  #
  teardown do
    Observatory::Probes::Database.reset!
  end
end
