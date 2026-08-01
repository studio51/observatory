# frozen_string_literal: true

module Observatory
  module Sql

    # One normalised query shape observed during a single execution, with its
    # counts and timings folded in.
    #
    # This is the object that makes an 86,000-query request legible: instead of
    # 86,000 rows it produces perhaps a dozen groups, one of which says "this
    # shape ran 41,722 times, 97% of them from the query cache, for 2.1 seconds
    # of database time" — which is the finding.
    #
    # Instances are mutable and live only for the duration of one request or job.
    # They are deliberately plain (no ActiveModel, no comparable) because a
    # pathological execution allocates one per distinct shape and up to
    # `max_query_groups` of them.
    #
    class QueryGroup
      attr_reader :fingerprint       # normalised, value-free SQL
      attr_reader :count             # total ActiveRecord lookups matching this shape
      attr_reader :cached_count      # lookups served by the ActiveRecord query cache
      attr_reader :executed_count    # lookups the database actually executed
      attr_reader :duration_ms       # summed duration across every lookup
      attr_reader :max_duration_ms   # slowest single lookup
      attr_reader :name              # ActiveRecord's name for the first lookup, e.g. "User Load"
      attr_reader :table             # table hint derived from the statement
      attr_reader :sample_sql        # redacted representative statement
      attr_reader :kind              # :query, :schema or :transaction
      attr_reader :call_site         # representative application call site, when captured
      attr_reader :row_count         # summed rows returned, where the adapter reports them

      # @param fingerprint [String] the normalised statement this group collects.
      # @param sample_sql [String] a redacted representative statement.
      # @param name [String, nil] ActiveRecord's name for the first observed lookup.
      # @param table [String, nil] table hint for the statement.
      # @param kind [Symbol] :query, :schema or :transaction.
      #
      # @return [Observatory::Sql::QueryGroup]
      #
      def initialize(fingerprint:, sample_sql:, name:, table:, kind:)
        @fingerprint     = fingerprint
        @sample_sql      = sample_sql
        @name            = name
        @table           = table
        @kind            = kind
        @count           = 0
        @cached_count    = 0
        @executed_count  = 0
        @duration_ms     = 0.0
        @max_duration_ms = 0.0
        @row_count       = 0
        @call_site       = nil
      end

      # Fold one observed lookup into the group.
      #
      # The hot path of the hot path: called once per query, up to the
      # `max_query_groups` ceiling, so it is arithmetic only.
      #
      # @param duration_ms [Float] how long the lookup took.
      # @param cached [Boolean] whether the ActiveRecord query cache served it.
      # @param rows [Integer] rows returned, where known.
      #
      # @return [void]
      #
      def record(duration_ms, cached, rows = 0)
        @count += 1
        @duration_ms += duration_ms
        @max_duration_ms = duration_ms if duration_ms > @max_duration_ms
        @row_count += rows

        if cached
          @cached_count += 1
        else
          @executed_count += 1
        end

        nil
      end

      # Attach the application call site that issued this query shape.
      #
      # Only ever set once, for groups that crossed the repetition threshold —
      # capturing a backtrace is the single most expensive thing Observatory can
      # do, so it happens at most `max_call_sites` times per execution.
      #
      # @param location [String] "path/to/file.rb:42:in `method'".
      #
      # @return [void]
      #
      def call_site=(location)
        @call_site ||= location
      end

      # Mean duration across every lookup in the group.
      #
      # @return [Float] milliseconds.
      #
      def average_duration_ms
        return 0.0 if @count.zero?

        @duration_ms / @count
      end

      # Share of this group's lookups served by the ActiveRecord query cache.
      #
      # @return [Float] 0.0-1.0.
      #
      def cached_ratio
        return 0.0 if @count.zero?

        @cached_count.to_f / @count
      end

      # Whether this group has repeated often enough to be worth a call site.
      #
      # @param threshold [Integer] repetitions required.
      #
      # @return [Boolean]
      #
      def repeated?(threshold)
        @count >= threshold
      end

      # The group as a plain hash, ready for `insert_all`.
      #
      # @return [Hash{Symbol => Object}]
      #
      def to_h
        {
          fingerprint:      @fingerprint,
          sample_sql:       @sample_sql,
          query_name:       @name,
          table_name:       @table,
          kind:             @kind.to_s,
          count:            @count,
          cached_count:     @cached_count,
          executed_count:   @executed_count,
          duration_ms:      @duration_ms.round(3),
          max_duration_ms:  @max_duration_ms.round(3),
          average_duration_ms: average_duration_ms.round(3),
          row_count:        @row_count,
          call_site:        @call_site,
        }
      end
    end
  end
end
