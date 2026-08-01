# frozen_string_literal: true

module Observatory

  # Deletes monitoring data once it has outlived its usefulness.
  #
  # ## Tiered by value, not by age alone
  #
  # An ordinary 200 that happened to be sampled is worth a day. A request that
  # raised is worth a month, because that is how long it takes for someone to
  # ask about it. Rollups are worth a quarter, because that is the window a
  # "compared with last month" question needs. Incidents are kept until someone
  # deletes them.
  #
  #   ordinary traces   24 hours
  #   anomalous traces  14 days
  #   error traces      30 days
  #   minute rollups    90 days
  #   daily rollups      1 year
  #   samples           14 days
  #   incidents         forever, unless configured otherwise
  #
  # ## Deleting carefully
  #
  # `delete_all` on a day's traces would be a single enormous transaction
  # holding locks on a table the writer is actively inserting into. So every
  # sweep is a bounded loop of small deletes with a ceiling on total work, on an
  # index the delete can seek — which is why `[retention_class, started_at]`
  # exists on the trace tables and is the sweep's only access path.
  #
  # The whole thing runs inside {Observatory::Instrumentation.suppress}: a
  # retention sweep issuing a few hundred deletes must not appear as a query
  # explosion in its own dashboard.
  #
  module Retention
    BATCH_SIZE = 5_000
    MAX_BATCHES_PER_SWEEP = 200   # ceiling: at most 1M rows per table per sweep

    module_function

    # Delete everything that has aged out.
    #
    # @param now [Time] the current time, injectable for tests.
    #
    # @return [Hash{Symbol => Integer}] rows deleted, by table.
    #
    def sweep!(now: Clock.wall)
      Safely.call("retention.sweep", fallback: {}) do
        Instrumentation.suppress do
          {
            request_traces:     sweep_traces(RequestTrace, now),
            job_traces:         sweep_traces(JobTrace, now),
            query_groups:       sweep_query_groups(now),
            route_rollups:      sweep_rollups(RouteRollup, now),
            job_rollups:        sweep_rollups(JobRollup, now),
            process_samples:    sweep_by_column(ProcessSample, :sampled_at, config.sample_retention, now),
            dependency_samples: sweep_by_column(DependencySample, :sampled_at, config.sample_retention, now),
            watchdog_events:    sweep_by_column(WatchdogEvent, :occurred_at, config.rollup_retention, now),
            incidents:          sweep_incidents(now),
          }
        end
      end
    end

    # Delete traces, one retention class at a time.
    #
    # Separate passes rather than one clever query: each pass is an index range
    # scan on `[retention_class, started_at]`, which a single `CASE`-based
    # condition could not use.
    #
    # @param model [Class] the trace model.
    # @param now [Time] the current time.
    #
    # @return [Integer] rows deleted.
    #
    def sweep_traces(model, now)
      %i[raw anomalous error].sum do |retention_class|
        cutoff = now - config.retention_for(retention_class)

        delete_in_batches(
          model.where(retention_class: retention_class.to_s).where(started_at: ...cutoff),
        )
      end
    end

    # Delete query groups whose trace has aged out.
    #
    # Keyed on the group's own `traced_at` copy rather than a join, so the delete
    # can seek an index instead of scanning both tables. That denormalised column
    # exists for exactly this.
    #
    # @param now [Time] the current time.
    #
    # @return [Integer] rows deleted.
    #
    def sweep_query_groups(now)
      cutoff = now - config.error_trace_retention

      delete_in_batches(QueryGroup.where(traced_at: ...cutoff))
    end

    # Delete rollups, minute buckets sooner than daily ones.
    #
    # @param model [Class] the rollup model.
    # @param now [Time] the current time.
    #
    # @return [Integer] rows deleted.
    #
    def sweep_rollups(model, now)
      minutes = delete_in_batches(
        model.where(granularity: "minute").where(bucket_at: ...(now - config.rollup_retention)),
      )
      days = delete_in_batches(
        model.where(granularity: "day").where(bucket_at: ...(now - config.daily_rollup_retention)),
      )

      minutes + days
    end

    # Delete rows older than a window, keyed on one timestamp column.
    #
    # @param model [Class] the model to sweep.
    # @param column [Symbol] the timestamp column.
    # @param window [Integer] seconds to keep.
    # @param now [Time] the current time.
    #
    # @return [Integer] rows deleted.
    #
    def sweep_by_column(model, column, window, now)
      delete_in_batches(model.where(column => ...(now - window)))
    end

    # Delete resolved incidents once they have aged out.
    #
    # Open incidents are never swept — an incident nobody has looked at is not an
    # incident that stopped mattering. `incident_retention` defaults to nil,
    # which keeps even resolved ones until a human decides otherwise.
    #
    # @param now [Time] the current time.
    #
    # @return [Integer] rows deleted.
    #
    def sweep_incidents(now)
      window = config.incident_retention
      return 0 if window.nil?

      cutoff = now - window
      scope = Incident.where(status: Incident::RESOLVED).where(ended_at: ...cutoff)

      IncidentEvidence.where(incident_id: scope.select(:id)).delete_all

      delete_in_batches(scope)
    end

    # Delete a scope in bounded batches.
    #
    # Two ceilings: `BATCH_SIZE` bounds each statement so no single delete holds
    # locks for long, and `MAX_BATCHES_PER_SWEEP` bounds the whole sweep so a
    # backlog from a period when the sweeper was not running gets cleared over
    # several sweeps rather than in one that runs for an hour.
    #
    # @param scope [ActiveRecord::Relation] the rows to delete.
    #
    # @return [Integer] rows deleted.
    #
    def delete_in_batches(scope)
      deleted = 0

      MAX_BATCHES_PER_SWEEP.times do
        batch = scope.limit(BATCH_SIZE).delete_all
        deleted += batch

        break if batch < BATCH_SIZE
      end

      deleted
    end

    # @return [Observatory::Configuration]
    #
    def config
      Observatory.config
    end
  end
end
