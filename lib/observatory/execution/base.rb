# frozen_string_literal: true

module Observatory
  module Execution

    # The accumulator for one unit of work — a request, a job, a health check.
    #
    # One of these exists per in-flight execution and lives entirely in memory.
    # Subscribers fold measurements into it as notifications arrive; nothing
    # touches the database, the network or the filesystem until {#finish!} hands
    # a compact summary to the pipeline. That is the whole reason the
    # instrumentation can afford to see all 86,000 queries in the pathological
    # request: seeing one costs an integer increment and a hash lookup.
    #
    # Bounded by construction (§5.2 of the brief):
    #
    # - query groups stop being created past `max_query_groups`, after which
    #   further shapes fold into a single `(overflow)` group;
    # - fingerprinting stops past `max_fingerprinted_queries`, after which
    #   queries are only counted;
    # - external-call and cache detail are aggregated, never listed.
    #
    # A pathological execution therefore has a *fixed* memory ceiling regardless
    # of how pathological it gets.
    #
    class Base
      OVERFLOW_FINGERPRINT = "(overflow: distinct query shapes beyond the retained limit)".freeze
      TRUNCATED_FINGERPRINT = "(truncated: fingerprinting ceiling reached)".freeze

      attr_reader :trace_id           # correlates every record produced by this execution
      attr_reader :started_at         # wall-clock start, for timelines
      attr_reader :started_monotonic  # monotonic start, for durations
      attr_reader :duration_ms        # total duration, set by #finish!
      attr_reader :query_groups       # fingerprint => QueryGroup
      attr_reader :external_calls     # host => aggregated external HTTP stats
      attr_reader :anomalies          # symbols flagged during collection
      attr_reader :exception_class    # class name of an unhandled exception, when one escaped
      attr_reader :exception_message  # redacted message of that exception

      # --- ActiveRecord tallies ---

      attr_reader :query_count        # every sql.active_record notification seen
      attr_reader :cached_query_count # those the ActiveRecord query cache served
      attr_reader :executed_query_count # those the database actually ran
      attr_reader :schema_query_count # schema introspection and DDL
      attr_reader :transaction_query_count # BEGIN/COMMIT/ROLLBACK/SAVEPOINT
      attr_reader :db_duration_ms     # summed ActiveRecord duration
      attr_reader :row_count          # summed rows returned
      attr_reader :instantiation_count # ActiveRecord objects materialised
      attr_reader :async_query_count  # queries issued through load_async

      # --- Other subsystems ---

      attr_reader :view_duration_ms   # time in ActionView rendering
      attr_reader :cache_read_count   # Rails.cache reads
      attr_reader :cache_hit_count    # of which hits
      attr_reader :cache_write_count  # Rails.cache writes
      attr_reader :cache_duration_ms  # time in the Rails cache store
      attr_reader :external_call_count # outbound HTTP calls
      attr_reader :external_duration_ms # time waiting on outbound HTTP
      attr_reader :external_error_count # outbound HTTP calls that failed

      # --- Process identity ---

      attr_reader :process_id         # OS pid, so a trace can be tied to a worker
      attr_reader :thread_id          # object_id of the executing thread
      attr_reader :hostname           # host that produced the trace
      attr_reader :release            # active deployment identifier

      # @param trace_id [String] correlation id for everything this execution emits.
      #
      # @return [Observatory::Execution::Base]
      #
      def initialize(trace_id:)
        @trace_id          = trace_id
        @started_at        = Clock.wall
        @started_monotonic = Clock.monotonic
        @gc_started        = GcSnapshot.capture
        @duration_ms       = nil

        @query_count             = 0
        @cached_query_count      = 0
        @executed_query_count    = 0
        @schema_query_count      = 0
        @transaction_query_count = 0
        @async_query_count       = 0
        @db_duration_ms          = 0.0
        @row_count               = 0
        @instantiation_count     = 0

        @view_duration_ms   = 0.0
        @cache_read_count   = 0
        @cache_hit_count    = 0
        @cache_write_count  = 0
        @cache_duration_ms  = 0.0
        @external_call_count = 0
        @external_duration_ms = 0.0
        @external_error_count = 0

        @query_groups     = {}
        @external_calls   = {}
        @anomalies        = []
        @call_sites_taken = 0
        @fingerprinted    = 0

        @process_id = Process.pid
        @thread_id  = Thread.current.object_id
        @hostname   = Observatory.hostname
        @release    = Observatory::Release.current
      end

      # Fold one `sql.active_record` notification into the tallies.
      #
      # Called once per query — including all 86,359 of them — so every branch
      # here is chosen for cost. The expensive parts (fingerprinting, call-site
      # capture) are behind ceilings that a pathological execution reaches and
      # then stops paying for.
      #
      # @param sql [String] the statement as issued.
      # @param name [String, nil] ActiveRecord's name for it, e.g. "Achievement Load".
      # @param duration_ms [Float] how long it took.
      # @param cached [Boolean] whether the ActiveRecord query cache served it.
      # @param rows [Integer] rows returned, where the adapter reports them.
      # @param async [Boolean] whether it was issued through load_async.
      #
      # @return [void]
      #
      def record_query(sql:, name:, duration_ms:, cached:, rows: 0, async: false)
        @query_count += 1
        @db_duration_ms += duration_ms
        @row_count += rows
        @async_query_count += 1 if async

        if cached
          @cached_query_count += 1
        else
          @executed_query_count += 1
        end

        kind = Sql::Fingerprint.classify(sql, name)

        case kind
        when :schema      then @schema_query_count += 1
        when :transaction then @transaction_query_count += 1
        end

        group = group_for(sql, name, kind)
        return if group.nil?

        group.record(duration_ms, cached, rows)
        capture_call_site(group) if group.call_site.nil?

        nil
      end

      # Record an ActiveRecord materialisation.
      #
      # @param count [Integer] records instantiated.
      #
      # @return [void]
      #
      def record_instantiation(count)
        @instantiation_count += count

        nil
      end

      # Record time spent rendering.
      #
      # @param duration_ms [Float] milliseconds in ActionView.
      #
      # @return [void]
      #
      def record_view(duration_ms)
        @view_duration_ms += duration_ms

        nil
      end

      # Record a Rails.cache operation.
      #
      # @param operation [Symbol] :read, :write, :delete or :read_multi.
      # @param duration_ms [Float] milliseconds in the cache store.
      # @param hit [Boolean, nil] whether a read hit; nil for non-reads.
      #
      # @return [void]
      #
      def record_cache(operation, duration_ms, hit: nil)
        @cache_duration_ms += duration_ms

        case operation
        when :read, :read_multi
          @cache_read_count += 1
          @cache_hit_count += 1 if hit
        when :write
          @cache_write_count += 1
        end

        nil
      end

      # Record one outbound HTTP call, aggregated by host.
      #
      # Individual calls are never listed — only per-host totals — so a job that
      # makes ten thousand API calls costs one hash entry, not ten thousand.
      #
      # @param host [String] the destination host, without scheme or path.
      # @param duration_ms [Float] milliseconds waiting on the call.
      # @param status [Integer, nil] response status, nil when the call failed outright.
      # @param error [Boolean] whether the call raised or timed out.
      #
      # @return [void]
      #
      def record_external_call(host:, duration_ms:, status: nil, error: false)
        @external_call_count += 1
        @external_duration_ms += duration_ms
        @external_error_count += 1 if error

        entry = (@external_calls[host] ||= { count: 0, duration_ms: 0.0, errors: 0, statuses: Hash.new(0) })
        entry[:count] += 1
        entry[:duration_ms] += duration_ms
        entry[:errors] += 1 if error
        entry[:statuses][status] += 1 if status

        nil
      end

      # Flag a condition worth retaining or reporting.
      #
      # @param name [Symbol] the anomaly, e.g. :cached_query_explosion.
      #
      # @return [void]
      #
      def flag(name)
        @anomalies << name unless @anomalies.include?(name)

        nil
      end

      # Attach an exception that escaped the execution.
      #
      # The message is truncated and stored, the backtrace is not — a backtrace
      # can carry interpolated values, and Sentry already has the full one.
      #
      # @param exception [Exception] what was raised.
      #
      # @return [void]
      #
      def record_exception(exception)
        @exception_class   = exception.class.name
        @exception_message = exception.message.to_s[0, 500]

        flag(:exception)

        nil
      end

      # Close the execution and compute its derived measurements.
      #
      # @return [self]
      #
      def finish!
        @duration_ms ||= Clock.elapsed_ms(@started_monotonic)
        @gc_finished ||= GcSnapshot.capture

        self
      end

      # Share of ActiveRecord lookups served by the query cache.
      #
      # The single most diagnostic ratio Observatory computes. A request with
      # 86,359 lookups at a 0.974 cached ratio and 2.1 seconds of database time
      # is not a database problem — it is application code in a loop, and MySQL
      # will look idle throughout.
      #
      # @return [Float] 0.0-1.0; 0.0 when no queries ran.
      #
      def cached_query_ratio
        return 0.0 if @query_count.zero?

        @cached_query_count.to_f / @query_count
      end

      # Estimated allocation and GC deltas across the execution.
      #
      # Process-wide and therefore contaminated by concurrent threads — see
      # {Observatory::GcSnapshot} for why this cannot be made exact on CRuby.
      #
      # @return [Hash{Symbol => Numeric}]
      #
      def gc_delta
        return EMPTY_GC_DELTA if @gc_finished.nil?

        @gc_finished.delta_from(@gc_started)
      end

      # Thread-seconds of request capacity this execution consumed.
      #
      # The unit that makes capacity risk comparable: ten requests of twenty
      # seconds cost ten times what a thousand requests of twenty milliseconds
      # cost, however the request counts look.
      #
      # @return [Float] seconds.
      #
      def thread_seconds
        (@duration_ms || Clock.elapsed_ms(@started_monotonic)) / 1_000.0
      end

      # Time not accounted for by the database, views, cache or external calls.
      #
      # Large values here are the signature of the failure mode this system was
      # built for: Ruby building queries, allocating objects and collecting
      # garbage, while every downstream dependency looks idle.
      #
      # @return [Float] milliseconds, floored at zero.
      #
      def unaccounted_ms
        total = @duration_ms || 0.0
        known = @db_duration_ms + @view_duration_ms + @cache_duration_ms + @external_duration_ms

        [ total - known, 0.0 ].max
      end

      # A stable label for grouping and baselines.
      #
      # Subclasses override this with something meaningful — a route template for
      # a request, a worker class for a job.
      #
      # @return [String]
      #
      def endpoint
        "unknown".freeze
      end

      # Whether this execution failed.
      #
      # Subclasses override with their own notion of failure.
      #
      # @return [Boolean]
      #
      def error?
        !@exception_class.nil?
      end

      # The most repeated query group, by count.
      #
      # @return [Observatory::Sql::QueryGroup, nil]
      #
      def dominant_query_group
        @query_groups.each_value.max_by(&:count)
      end

      # The query group that owns the most database time.
      #
      # @return [Observatory::Sql::QueryGroup, nil]
      #
      def slowest_query_group
        @query_groups.each_value.max_by(&:duration_ms)
      end

      # Whether the fingerprinting ceiling was reached, making group counts a
      # lower bound rather than a total.
      #
      # @return [Boolean]
      #
      def fingerprinting_truncated?
        @fingerprinted >= Observatory.config.max_fingerprinted_queries
      end

      # Empty deltas, returned when an execution is inspected before it finishes.
      #
      EMPTY_GC_DELTA = {
        allocation_delta: 0, freed_delta: 0, gc_runs: 0, major_gc_runs: 0, estimated_gc_time_ms: 0.0,
      }.freeze

    private

      # Find or create the group for a statement, respecting both ceilings.
      #
      # Past `max_fingerprinted_queries` the statement is not normalised at all
      # and folds into a single truncation group; past `max_query_groups` a new
      # shape folds into a single overflow group. Either way the memory cost
      # stops growing.
      #
      # @param sql [String] the statement.
      # @param name [String, nil] ActiveRecord's name for it.
      # @param kind [Symbol] :query, :schema or :transaction.
      #
      # @return [Observatory::Sql::QueryGroup]
      #
      def group_for(sql, name, kind)
        config = Observatory.config

        if @fingerprinted >= config.max_fingerprinted_queries
          return (@query_groups[TRUNCATED_FINGERPRINT] ||= overflow_group(TRUNCATED_FINGERPRINT))
        end

        @fingerprinted += 1
        fingerprint = Sql::Fingerprint.call(sql)
        existing = @query_groups[fingerprint]
        return existing if existing

        if @query_groups.size >= config.max_query_groups
          return (@query_groups[OVERFLOW_FINGERPRINT] ||= overflow_group(OVERFLOW_FINGERPRINT))
        end

        @query_groups[fingerprint] = Sql::QueryGroup.new(
          fingerprint:,
          sample_sql: Sql::Fingerprint.redact(sql),
          name:,
          table: Sql::Fingerprint.table_for(sql),
          kind:,
        )
      end

      # A placeholder group standing in for everything past a ceiling.
      #
      # @param fingerprint [String] the marker fingerprint.
      #
      # @return [Observatory::Sql::QueryGroup]
      #
      def overflow_group(fingerprint)
        flag(:query_groups_truncated)

        Sql::QueryGroup.new(fingerprint:, sample_sql: fingerprint, name: nil, table: nil, kind: :query)
      end

      # Take a representative application call site for a repeatedly-executed
      # query shape.
      #
      # This is the most expensive operation in the whole collection path, so it
      # is fenced three ways: it must be enabled, the shape must already have
      # repeated `query_call_site_threshold` times, and at most `max_call_sites`
      # are taken per execution. In the pathological request that means three
      # backtraces out of 86,359 queries.
      #
      # @param group [Observatory::Sql::QueryGroup] the repeating group.
      #
      # @return [void]
      #
      def capture_call_site(group)
        config = Observatory.config
        return unless config.capture_query_call_sites
        return if @call_sites_taken >= config.max_call_sites
        return unless group.repeated?(config.query_call_site_threshold)

        location = CallSite.find(config)
        return if location.nil?

        group.call_site = location
        @call_sites_taken += 1

        nil
      end
    end
  end
end
