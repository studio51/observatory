# frozen_string_literal: true

module Observatory
  module Pipeline

    # The background thread that drains the buffer into the database.
    #
    # ## Why a thread and not a job
    #
    # The obvious alternative is enqueuing a Sidekiq job per batch. That would
    # put monitoring writes behind whatever else is in the queue — which, during
    # the incident this system exists to explain, is exactly when the queue is
    # deepest and the data is most needed. It would also mean Observatory's own
    # jobs running through Observatory's own Sidekiq middleware, which is the
    # recursion the suppression mechanism exists to prevent.
    #
    # A dedicated thread has none of those properties. It is permanently
    # suppressed, it owns its own connection from the pool, and it is entirely
    # independent of the application's own work.
    #
    # ## Fork safety
    #
    # Puma runs `preload_app!` with three workers. A thread started in the master
    # does not survive `fork` — it simply does not exist in the child, silently.
    # So the writer records the pid it was started under and restarts itself if
    # it ever finds it has been forked into a new process. {Observatory.start!} is
    # also called from `on_worker_boot`, which is the belt to this braces.
    #
    # ## Shutdown
    #
    # `at_exit` drains what is buffered, with a deadline. A deploy restarts Puma
    # every time it cuts over, so without a drain the last few seconds before
    # every deploy would be missing from the record — which is precisely the
    # window most worth having when a deploy causes a regression.
    #
    module Writer
      SHUTDOWN_DRAIN_SECONDS = 5.0
      RESTART_BACKOFF_SECONDS = 5.0

      class << self

        # Start the writer thread if it is not already running in this process.
        #
        # @return [Thread, nil] the writer thread, or nil when disabled.
        #
        def start!
          return nil unless Observatory.config.writer_enabled
          return nil unless Observatory.config.persist?
          return @thread if running?

          @pid = Process.pid
          @stopping = false
          @thread = Thread.new { run }
          @thread.name = "observatory-writer"
          @thread.abort_on_exception = false

          install_shutdown_hook

          @thread
        end

        # Stop the writer, draining what is buffered first.
        #
        # @param timeout [Float] seconds to wait for the drain.
        #
        # @return [void]
        #
        def stop!(timeout: SHUTDOWN_DRAIN_SECONDS)
          @stopping = true
          thread = @thread
          @thread = nil

          drain!(timeout:)
          thread&.kill if thread&.alive?

          nil
        end

        # Whether the writer is running in *this* process.
        #
        # False after a fork, which is what makes the fork guard work.
        #
        # @return [Boolean]
        #
        def running?
          !@thread.nil? && @thread.alive? && @pid == Process.pid
        end

        # Write whatever is buffered, now, on the calling thread.
        #
        # @param timeout [Float] seconds to keep draining before giving up.
        #
        # @return [Integer] events written.
        #
        def drain!(timeout: SHUTDOWN_DRAIN_SECONDS)
          deadline = Clock.monotonic + timeout
          written = 0

          while Clock.monotonic < deadline
            batch = Pipeline.buffer.pop_batch(timeout: 0)
            break if batch.empty?

            written += write_now(batch)
          end

          written
        end

        # Persist a batch of serialised executions.
        #
        # Everything here runs inside {Observatory::Instrumentation.suppress}, so
        # the writes it performs are invisible to the subscribers — otherwise a
        # flush of 250 traces would itself look like a query explosion.
        #
        # @param payloads [Array<Hash>] {Observatory::Serializer} results.
        #
        # @return [Integer] events written.
        #
        def write_now(payloads)
          return 0 if payloads.empty?

          Safely.call("pipeline.writer.write", fallback: 0) do
            Instrumentation.suppress do
              requests, jobs = payloads.partition { |payload| payload[:kind] == :request }

              written = insert_traces(RequestTrace, requests) + insert_traces(JobTrace, jobs)
              @written = @written.to_i + written

              written
            end
          end
        end

        # How the writer has been coping, for the diagnostics panel.
        #
        # @return [Hash{Symbol => Object}]
        #
        def stats
          {
            running:  running?,
            pid:      @pid,
            written:  @written.to_i,
            failures: Safely.failure_counts.select { |label, _| label.start_with?("pipeline.writer") }.values.sum,
          }.merge(Pipeline.buffer.stats)
        end

        # Forget all state. Test-suite hygiene only.
        #
        # @return [void]
        #
        def reset!
          @thread = nil
          @pid = nil
          @written = 0
          @stopping = false

          nil
        end

      private

        # The writer loop.
        #
        # @return [void]
        #
        def run
          Instrumentation.suppress_thread!

          until @stopping
            batch = Pipeline.buffer.pop_batch
            next if batch.empty?

            write_now(batch)
          end
        rescue Exception => exception # rubocop:disable Lint/RescueException
          Safely.call("pipeline.writer.crashed") { raise exception }
          restart_after_crash
        end

        # Bring the writer back after an unexpected crash.
        #
        # A monitoring system whose writer dies silently is worse than one that
        # is switched off, because it still looks installed. The backoff stops a
        # persistently failing writer from spinning.
        #
        # @return [void]
        #
        def restart_after_crash
          return if @stopping

          @thread = nil
          Thread.new do
            sleep(RESTART_BACKOFF_SECONDS)
            start!
          end

          nil
        end

        # Insert a batch of traces and their query groups.
        #
        # `insert_all` rather than `create!`: no validations to run, no callbacks
        # to fire, no model instances to allocate, and one round trip for 250
        # rows instead of 250 round trips.
        #
        # @param model [Class] the trace model.
        # @param payloads [Array<Hash>] the payloads to insert.
        #
        # @return [Integer] traces written.
        #
        def insert_traces(model, payloads)
          return 0 if payloads.empty?

          rows = payloads.map { |payload| trace_row(model, payload) }
          ids = insert_and_resolve_ids(model, rows)

          insert_query_groups(model, payloads, ids)

          rows.size
        end

        # Insert the rows and return their ids, in the order they were given.
        #
        # `insert_all(returning:)` is PostgreSQL-only — MySQL raises
        # `ArgumentError: does not support :returning` — so on MySQL the ids are
        # resolved with one follow-up `pluck` keyed on the trace ids we generated
        # ourselves. That is two round trips per batch of 250 rather than one,
        # which is a fair price for the query groups being attachable at all.
        #
        # @param model [Class] the trace model.
        # @param rows [Array<Hash>] the rows being inserted.
        #
        # @return [Array<Integer, nil>] ids positionally matching `rows`.
        #
        def insert_and_resolve_ids(model, rows)
          if supports_returning?(model)
            result = model.insert_all(rows, returning: %w[id])

            return Array(result&.rows).flatten
          end

          model.insert_all(rows)

          trace_ids = rows.filter_map { |row| row[:trace_id] }
          return [] if trace_ids.empty?

          by_trace_id = model.where(trace_id: trace_ids).pluck(:trace_id, :id).to_h

          rows.map { |row| by_trace_id[row[:trace_id]] }
        end

        # @param model [Class] the trace model.
        #
        # @return [Boolean] whether the adapter can return ids from a bulk insert.
        #
        def supports_returning?(model)
          @supports_returning = model.connection.supports_insert_returning? if @supports_returning.nil?

          @supports_returning
        end

        # Insert the query groups belonging to a batch of traces.
        #
        # @param model [Class] the trace model the groups belong to.
        # @param payloads [Array<Hash>] the payloads that were inserted.
        # @param ids [Array<Integer>] the ids `insert_all` returned, in order.
        #
        # @return [void]
        #
        def insert_query_groups(model, payloads, ids)
          kind = model == RequestTrace ? QueryGroup::REQUEST : QueryGroup::JOB
          rows = []

          payloads.each_with_index do |payload, index|
            trace_row_id = ids[index]
            next if trace_row_id.nil?

            traced_at = payload.dig(:trace, :started_at)

            Array(payload[:query_groups]).each do |group|
              rows << group.slice(
                :sample_sql, :query_name, :table_name, :kind, :count, :cached_count,
                :executed_count, :duration_ms, :max_duration_ms, :average_duration_ms,
                :row_count, :call_site,
              ).merge(
                trace_kind: kind, trace_row_id:, traced_at:,
                fingerprint: group[:fingerprint],
                fingerprint_digest: QueryGroup.digest(group[:fingerprint]),
              )
            end
          end

          QueryGroup.insert_all(rows) if rows.any?

          nil
        end

        # Reduce a payload to the columns the table actually has.
        #
        # Guards against a serialiser change silently breaking every write: an
        # unknown key is dropped rather than raising, and a column added to the
        # table starts being populated as soon as the serialiser emits it.
        #
        # @param model [Class] the trace model.
        # @param payload [Hash] the payload to reduce.
        #
        # @return [Hash{Symbol => Object}]
        #
        def trace_row(model, payload)
          columns = trace_columns(model)

          payload[:trace].slice(*columns)
        end

        # @param model [Class] the trace model.
        #
        # @return [Array<Symbol>] its column names, memoised per model.
        #
        def trace_columns(model)
          @trace_columns ||= {}
          @trace_columns[model.name] ||= model.column_names.map(&:to_sym) - %i[id]
        end

        # Drain the buffer at process exit so a deploy does not lose the seconds
        # immediately before it.
        #
        # @return [void]
        #
        def install_shutdown_hook
          return if @shutdown_hook_installed

          @shutdown_hook_installed = true
          at_exit { Safely.call("pipeline.writer.shutdown") { stop! } }

          nil
        end
      end
    end
  end
end
