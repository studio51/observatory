# frozen_string_literal: true

module Observatory

  # The abstract base every Observatory model inherits from.
  #
  # ## Why a separate base class
  #
  # Two reasons, both about blast radius.
  #
  # **Connection isolation is one line away.** If `database.yml` grows an
  # `observatory` entry, this class connects to it and every monitoring row moves
  # off the primary — no model changes, no query changes. Without a shared base
  # that would be a migration of a dozen classes. Today it falls through to the
  # primary connection, which is the only safe, repo-compatible thing that works
  # in this application (see the architecture note); the escape hatch exists
  # because the volume estimate says it may be needed later.
  #
  # **Every query these models make is suppressed.** A monitoring read on the
  # dashboard, or a monitoring write from the batch writer, must not appear in
  # anybody's trace. The writer and the sweepers wrap themselves in
  # {Observatory::Instrumentation.suppress}; this base is where the convention
  # lives.
  #
  # These are append-only fact tables with no foreign keys — to application
  # tables or to each other. A monitoring row must never be able to lock, block
  # or cascade into an application row.
  #
  class Record < ActiveRecord::Base
    self.abstract_class = true

    # The `database.yml` key Observatory uses when one is configured.
    #
    CONNECTION_NAME = :observatory

    class << self

      # Point the model at a dedicated database when one is configured.
      #
      # Called from the engine at boot. A no-op when `database.yml` has no
      # `observatory` entry, which is the current state — monitoring rows live on
      # the primary connection alongside everything else.
      #
      # @return [Boolean] whether a dedicated connection was configured.
      #
      def connect_to_configured_database!
        return false unless dedicated_database?

        connects_to(database: { writing: CONNECTION_NAME, reading: CONNECTION_NAME })

        true
      end

      # Whether `database.yml` declares a dedicated Observatory database for the
      # current environment.
      #
      # @return [Boolean]
      #
      def dedicated_database?
        ActiveRecord::Base.configurations
                          .configs_for(env_name: Rails.env.to_s)
                          .any? { |config| config.name.to_sym == CONNECTION_NAME }
      rescue StandardError
        false
      end
    end
  end
end
