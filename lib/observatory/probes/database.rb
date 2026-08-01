# frozen_string_literal: true

module Observatory
  module Probes

    # Reads the Rails connection pool and, where available, MySQL itself.
    #
    # These two layers answer different questions and the difference decides
    # incidents. The pool answers "is the *application* waiting to talk to the
    # database?"; MySQL answers "is the *database* struggling?". An incident
    # where the answer to both is no, while requests take fourteen seconds, is
    # precisely the one that gets misdiagnosed as a database problem — so being
    # able to state both negatives, with numbers, is a feature and not an
    # afterthought.
    #
    #   MySQL is not the bottleneck
    #   - 54 of 10,000 connections in use
    #   - 2 running threads
    #   - no row-lock waits
    #   - no connection checkout wait in Rails
    #
    # ## On not reasoning from defaults
    #
    # Every MySQL figure here is measured from the running server. The
    # `max_connections` this application actually has is whatever the server was
    # started with, and asserting the documentation default would be exactly the
    # sort of confident wrongness this system exists to replace.
    #
    module Database
      POOL_KEYS = %i[size connections busy dead idle waiting checkout_timeout].freeze

      # Global status counters worth sampling. Read in one round trip.
      #
      GLOBAL_STATUS = %w[
        Threads_connected Threads_running Threads_created Max_used_connections
        Connections Aborted_connects Slow_queries Queries Questions
        Innodb_row_lock_waits Innodb_row_lock_time Innodb_row_lock_time_avg
        Innodb_buffer_pool_wait_free Innodb_buffer_pool_reads
        Innodb_buffer_pool_read_requests Innodb_deadlocks
        Created_tmp_disk_tables Created_tmp_tables Table_locks_waited
      ].freeze

      # Server variables worth sampling. These are the values that must be
      # measured rather than assumed.
      #
      GLOBAL_VARIABLES = %w[
        max_connections max_execution_time wait_timeout
        innodb_buffer_pool_size long_query_time
      ].freeze

      class << self

        # The Rails connection pool gauge for the primary pool.
        #
        # Cheap enough to sample at the end of every request: `ConnectionPool#stat`
        # takes the pool's own mutex and reads counters, with no database round
        # trip. `waiting` is the field that matters — a non-zero value means
        # application threads are blocked waiting for a connection, which is a
        # completely different failure from a slow query.
        #
        # @return [Hash{Symbol => Integer}, nil] nil when ActiveRecord is not connected.
        #
        def pool_stat
          return nil unless defined?(::ActiveRecord::Base)

          Safely.call("probes.database.pool_stat") do
            pool = ::ActiveRecord::Base.connection_pool
            next nil if pool.nil?

            pool.stat.slice(*POOL_KEYS)
          end
        end

        # Pool gauges for every connected pool, keyed by role and shard.
        #
        # @return [Array<Hash{Symbol => Object}>]
        #
        def pool_stats
          return [] unless defined?(::ActiveRecord::Base)

          Safely.call("probes.database.pool_stats", fallback: []) do
            ::ActiveRecord::Base.connection_handler.connection_pool_list(:all).map do |pool|
              pool.stat.slice(*POOL_KEYS).merge(
                role:  pool.db_config.name,
                shard: pool.shard.to_s,
                database: pool.db_config.database,
              )
            end
          end
        end

        # A measured snapshot of the MySQL server.
        #
        # Runs three cheap statements inside {Observatory::Instrumentation.suppress},
        # so the probe's own queries never appear in anybody's trace.
        #
        # @return [Hash{Symbol => Object}, nil] nil when unavailable or disabled.
        #
        def server_sample
          return nil unless Observatory.config.mysql_probe_enabled
          return nil unless defined?(::ActiveRecord::Base)

          Safely.call("probes.database.server_sample") do
            Instrumentation.suppress do
              status    = global_status
              variables = global_variables
              next nil if status.empty?

              build_sample(status, variables)
            end
          end
        end

        # Statements currently executing for longer than the given threshold.
        #
        # Read from `information_schema.processlist` and deliberately reduced to
        # counts and durations plus a redacted statement shape — a live query text
        # can contain production values, and this system does not store those.
        #
        # @param seconds [Integer] minimum age of a statement to report.
        # @param limit [Integer] maximum statements to return.
        #
        # @return [Array<Hash{Symbol => Object}>]
        #
        def long_running_statements(seconds: 5, limit: 10)
          return [] unless Observatory.config.mysql_probe_enabled
          return [] unless mysql?

          Safely.call("probes.database.long_running", fallback: []) do
            Instrumentation.suppress do
              rows = select_all(<<~SQL.squish, [ seconds, limit ])
                SELECT id, user, db, command, time, state, LEFT(info, 500) AS info
                FROM information_schema.processlist
                WHERE command <> 'Sleep' AND time >= ?
                ORDER BY time DESC
                LIMIT ?
              SQL

              rows.map do |row|
                {
                  id:       row["id"],
                  user:     row["user"],
                  database: row["db"],
                  command:  row["command"],
                  seconds:  row["time"].to_i,
                  state:    row["state"],
                  statement: Sql::Fingerprint.redact(row["info"]),
                }
              end
            end
          end
        end

        # Whether the primary connection is MySQL, and therefore whether the
        # server probes apply at all.
        #
        # @return [Boolean]
        #
        def mysql?
          return false unless defined?(::ActiveRecord::Base)

          @mysql = Safely.call("probes.database.adapter", fallback: false) do
            ::ActiveRecord::Base.connection_db_config.adapter.to_s.start_with?("mysql")
          end if @mysql.nil?

          @mysql
        end

        # Forget memoised adapter detection. Test-suite hygiene only.
        #
        # @return [void]
        #
        def reset!
          @mysql = nil

          nil
        end

      private

        # @param status [Hash{String => String}] SHOW GLOBAL STATUS as a hash.
        # @param variables [Hash{String => String}] SHOW GLOBAL VARIABLES as a hash.
        #
        # @return [Hash{Symbol => Object}]
        #
        def build_sample(status, variables)
          connections = status["Threads_connected"].to_i
          maximum     = variables["max_connections"].to_i

          {
            connections:          connections,
            max_connections:      maximum,
            peak_connections:     status["Max_used_connections"].to_i,
            connection_saturation: maximum.positive? ? (connections.to_f / maximum).round(4) : nil,
            running_threads:      status["Threads_running"].to_i,
            aborted_connects:     status["Aborted_connects"].to_i,
            slow_queries:         status["Slow_queries"].to_i,
            questions:            status["Questions"].to_i,
            row_lock_waits:       status["Innodb_row_lock_waits"].to_i,
            row_lock_time_ms:     status["Innodb_row_lock_time"].to_i,
            row_lock_time_avg_ms: status["Innodb_row_lock_time_avg"].to_i,
            deadlocks:            status["Innodb_deadlocks"].to_i,
            buffer_pool_waits:    status["Innodb_buffer_pool_wait_free"].to_i,
            buffer_pool_hit_ratio: buffer_pool_hit_ratio(status),
            tmp_disk_tables:      status["Created_tmp_disk_tables"].to_i,
            tmp_tables:           status["Created_tmp_tables"].to_i,
            table_locks_waited:   status["Table_locks_waited"].to_i,
            max_execution_time_ms: variables["max_execution_time"].to_i,
            long_query_time:      variables["long_query_time"].to_f,
          }
        end

        # InnoDB buffer-pool hit ratio, the standard indicator of whether the
        # working set fits in memory.
        #
        # @param status [Hash{String => String}] SHOW GLOBAL STATUS as a hash.
        #
        # @return [Float, nil] 0.0-1.0, or nil when the counters are absent.
        #
        def buffer_pool_hit_ratio(status)
          requests = status["Innodb_buffer_pool_read_requests"].to_i
          reads    = status["Innodb_buffer_pool_reads"].to_i
          return nil unless requests.positive?

          (1.0 - (reads.to_f / requests)).round(4)
        end

        # @return [Hash{String => String}] the sampled global status counters.
        #
        def global_status
          fetch_pairs("SHOW GLOBAL STATUS", GLOBAL_STATUS)
        end

        # @return [Hash{String => String}] the sampled global variables.
        #
        def global_variables
          fetch_pairs("SHOW GLOBAL VARIABLES", GLOBAL_VARIABLES)
        end

        # Run a `SHOW` statement and keep only the rows we asked for.
        #
        # A `LIKE` per name would be N round trips; one unfiltered `SHOW` plus an
        # in-Ruby filter is one round trip and a few hundred discarded rows, which
        # is the cheaper trade at a fifteen-second sampling interval.
        #
        # @param statement [String] the SHOW statement to run.
        # @param names [Array<String>] the variable names to keep.
        #
        # @return [Hash{String => String}]
        #
        def fetch_pairs(statement, names)
          return {} unless mysql?

          wanted = names.to_set
          rows = select_all(statement)

          rows.each_with_object({}) do |row, collected|
            name = row["Variable_name"]
            collected[name] = row["Value"] if wanted.include?(name)
          end
        end

        # @param statement [String] the SQL to run.
        # @param binds [Array] positional bind values.
        #
        # @return [Array<Hash>] rows as hashes.
        #
        def select_all(statement, binds = [])
          connection = ::ActiveRecord::Base.connection
          sql = binds.empty? ? statement : ::ActiveRecord::Base.sanitize_sql_array([ statement, *binds ])

          connection.select_all(sql, "Observatory Probe").to_a
        end
      end
    end
  end
end
