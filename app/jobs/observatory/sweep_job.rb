# frozen_string_literal: true

module Observatory

  # Deletes monitoring data that has aged out, and runs one detection cycle.
  #
  # ## Not instrumented, by construction
  #
  # This job issues hundreds of deletes and reads a few hundred rows. Measured,
  # it would file a query explosion against Observatory every hour. Two things
  # stop that: the whole body runs inside {Observatory::Instrumentation.suppress},
  # and {Observatory::Sidekiq::Middleware} skips any job whose class sits under
  # the `Observatory::` namespace before it builds a context at all.
  #
  # It runs on its own queue for the same reason a monitoring write is not a
  # Sidekiq job: during an incident the default queue is deepest, and retention
  # falling behind is how a disk fills.
  #
  class SweepJob < ActiveJob::Base
    queue_as :observatory

    # Run retention, then analysis.
    #
    # That order matters. Analysing first would let a rule fire on rows the sweep
    # is about to delete, opening an incident whose evidence immediately
    # vanishes.
    #
    # @return [Hash{Symbol => Object}] what was deleted and what was found.
    #
    def perform
      Instrumentation.suppress do
        deleted  = Retention.sweep!
        analysis = Analysis::Engine.run!

        Observatory.logger.info(
          "[observatory] sweep deleted #{deleted.values.sum} rows; " \
          "analysis opened #{analysis[:opened].to_i}, updated #{analysis[:updated].to_i}, " \
          "resolved #{analysis[:resolved].to_i}",
        )

        { deleted:, analysis: }
      end
    end
  end
end
