# frozen_string_literal: true

# Every table Observatory owns, created in one migration.
#
# ## Shape
#
# All of these are **append-only fact tables**: rows are inserted in batches,
# read by the dashboard, and deleted wholesale by the retention sweep. There are
# no foreign keys to application tables and no foreign keys between these tables
# either — a monitoring row must never be able to block, cascade into, or lock
# an application row, and an incident must never fail to record because the
# trace it references was already swept.
#
# ## The row-count decision
#
# One row per query would mean 86,359 rows for a single request. Instead a
# retained execution produces **one** trace row plus one row per distinct
# normalised query shape — three, for that request. That ratio is the entire
# storage strategy.
#
# Rollups are separate and are computed from *every* execution, not only the
# sampled ones, so "how many requests did this route serve?" is a true count
# rather than a sample extrapolation. Latency percentiles come from a fixed
# log-spaced histogram stored on the rollup, which is exact enough to act on and
# costs one JSON column instead of a row per request.
#
class CreateObservatoryTables < ActiveRecord::Migration[8.1]

  # @return [void]
  #
  def change
    create_request_traces
    create_job_traces
    create_query_groups
    create_route_rollups
    create_job_rollups
    create_process_samples
    create_dependency_samples
    create_deployments
    create_watchdog_events
    create_incidents
    create_incident_evidence
  end

private

  # One retained HTTP request.
  #
  # @return [void]
  #
  def create_request_traces
    create_table :observatory_request_traces do |t|
      t.string   :trace_id, null: false, limit: 32
      t.string   :request_id, limit: 64
      t.datetime :started_at, null: false, precision: 6
      t.float    :duration_ms, null: false, default: 0.0

      # Identity. `endpoint` is the grouping key and is the route template, not
      # the literal path — a path cannot be grouped, has no baseline and carries
      # identifiers that should not be stored.
      t.string  :endpoint, null: false, limit: 255
      t.string  :route, limit: 255
      t.string  :controller, limit: 255
      t.string  :action, limit: 64
      t.string  :http_method, limit: 8
      t.integer :status, limit: 2
      t.integer :response_bytes
      t.float   :queue_wait_ms                       # nil means unmeasured, never zero
      t.boolean :health_check, null: false, default: false

      # Traffic attribution.
      t.string  :traffic_class, limit: 32
      t.string  :user_agent_family, limit: 32
      t.string  :client_id, limit: 32                # HMAC with a rotating salt, never an address
      t.integer :concurrent_requests, limit: 2, null: false, default: 0
      t.integer :peak_concurrency, limit: 2, null: false, default: 0
      t.float   :thread_seconds, null: false, default: 0.0

      add_execution_measurements(t)

      t.index :trace_id
      t.index :started_at
      t.index [ :endpoint, :started_at ]
      t.index [ :retention_class, :started_at ]      # the retention sweep's only access path
      t.index [ :client_id, :started_at ]            # crawler amplification
      t.index :incident_id
    end
  end

  # One retained Sidekiq job.
  #
  # @return [void]
  #
  def create_job_traces
    create_table :observatory_job_traces do |t|
      t.string   :trace_id, null: false, limit: 32
      t.string   :jid, limit: 40
      t.datetime :started_at, null: false, precision: 6
      t.float    :duration_ms, null: false, default: 0.0

      t.string   :endpoint, null: false, limit: 255  # the worker class
      t.string   :job_class, limit: 255
      t.string   :queue, limit: 64
      t.datetime :enqueued_at, precision: 6
      t.float    :queue_latency_ms                   # the number that separates "deep" from "not draining"
      t.integer  :retry_count, null: false, default: 0
      t.string   :batch_id, limit: 40
      t.string   :result, limit: 16
      t.float    :throttle_wait_ms
      t.float    :lock_wait_ms
      t.string   :sidekiq_process, limit: 128
      t.float    :worker_seconds, null: false, default: 0.0

      add_execution_measurements(t)

      t.index :trace_id
      t.index :started_at
      t.index [ :endpoint, :started_at ]
      t.index [ :queue, :started_at ]
      t.index [ :retention_class, :started_at ]
      t.index :incident_id
    end
  end

  # One normalised query shape observed during one retained execution.
  #
  # Not one row per query — one row per *shape*. The 86,359-query request
  # produces three of these.
  #
  # @return [void]
  #
  def create_query_groups
    create_table :observatory_query_groups do |t|
      t.string   :trace_kind, null: false, limit: 8  # "request" or "job"
      t.bigint   :trace_row_id, null: false
      t.datetime :traced_at, null: false, precision: 6

      t.text    :fingerprint, null: false            # normalised, value-free SQL
      t.string  :fingerprint_digest, null: false, limit: 32 # for grouping shapes across traces
      t.text    :sample_sql                          # redacted representative statement
      t.string  :query_name, limit: 128
      t.string  :table_name, limit: 64
      t.string  :kind, null: false, limit: 16, default: "query"

      t.integer :count, null: false, default: 0
      t.integer :cached_count, null: false, default: 0
      t.integer :executed_count, null: false, default: 0
      t.float   :duration_ms, null: false, default: 0.0
      t.float   :max_duration_ms, null: false, default: 0.0
      t.float   :average_duration_ms, null: false, default: 0.0
      t.integer :row_count, null: false, default: 0
      t.string  :call_site, limit: 255               # the application line inside the loop

      t.index [ :trace_kind, :trace_row_id ]
      t.index [ :fingerprint_digest, :traced_at ]
      t.index :traced_at
    end
  end

  # Per-minute and per-day aggregates for one route.
  #
  # Computed from every request, not only the sampled ones, so counts are true.
  #
  # @return [void]
  #
  def create_route_rollups
    create_table :observatory_route_rollups do |t|
      add_rollup_dimensions(t)

      t.string  :endpoint, null: false, limit: 255
      t.integer :error_count, null: false, default: 0
      t.integer :crawler_count, null: false, default: 0
      t.float   :thread_seconds, null: false, default: 0.0
      t.bigint  :response_bytes_sum, null: false, default: 0

      add_rollup_measurements(t)

      t.index [ :granularity, :bucket_at, :endpoint, :release ],
              unique: true, name: "index_observatory_route_rollups_on_bucket"
      t.index [ :bucket_at, :granularity ]
      t.index [ :endpoint, :bucket_at ]
    end
  end

  # Per-minute and per-day aggregates for one job class.
  #
  # @return [void]
  #
  def create_job_rollups
    create_table :observatory_job_rollups do |t|
      add_rollup_dimensions(t)

      t.string  :job_class, null: false, limit: 255
      t.string  :queue, null: false, limit: 64, default: ""
      t.integer :failure_count, null: false, default: 0
      t.integer :retry_count, null: false, default: 0
      t.float   :worker_seconds, null: false, default: 0.0
      t.float   :queue_latency_sum_ms, null: false, default: 0.0
      t.float   :queue_latency_max_ms, null: false, default: 0.0

      add_rollup_measurements(t)

      t.index [ :granularity, :bucket_at, :job_class, :queue, :release ],
              unique: true, name: "index_observatory_job_rollups_on_bucket"
      t.index [ :bucket_at, :granularity ]
      t.index [ :job_class, :bucket_at ]
    end
  end

  # A periodic reading of one process: Puma capacity, memory, GC, pool.
  #
  # @return [void]
  #
  def create_process_samples
    create_table :observatory_process_samples do |t|
      t.datetime :sampled_at, null: false, precision: 6
      t.string   :hostname, null: false, limit: 64
      t.integer  :process_id, null: false
      t.string   :role, null: false, limit: 16       # "web" or "sidekiq"
      t.integer  :worker_index, limit: 2

      # Puma capacity. `capacity_source` names which adapter layer answered, so
      # the dashboard never presents a fallback reading as ground truth.
      t.string  :capacity_source, limit: 16
      t.integer :max_threads, limit: 2
      t.integer :busy_threads, limit: 2
      t.integer :idle_threads, limit: 2
      t.integer :backlog                             # nil means unknown, NOT zero
      t.integer :backlog_max
      t.boolean :saturated, null: false, default: false
      t.float   :saturated_for_seconds

      t.bigint  :rss_bytes
      t.float   :cpu_seconds
      t.bigint  :allocated_objects
      t.integer :gc_count
      t.integer :major_gc_count
      t.float   :gc_total_time_ms
      t.bigint  :heap_live_slots
      t.bigint  :heap_available_slots
      t.bigint  :old_objects

      t.integer :pool_size, limit: 2
      t.integer :pool_busy, limit: 2
      t.integer :pool_waiting, limit: 2

      t.string  :release, limit: 64
      t.json    :details

      t.index :sampled_at
      t.index [ :role, :sampled_at ]
      t.index [ :hostname, :process_id, :sampled_at ], name: "index_observatory_process_samples_on_process"
    end
  end

  # A periodic reading of one dependency: MySQL, Redis or a Sidekiq queue.
  #
  # @return [void]
  #
  def create_dependency_samples
    create_table :observatory_dependency_samples do |t|
      t.datetime :sampled_at, null: false, precision: 6
      t.string   :dependency, null: false, limit: 32 # "mysql", "redis", "sidekiq"
      t.string   :subject, null: false, limit: 64, default: "" # queue name, shard, …

      t.float  :utilisation                          # 0.0-1.0, calculated not inferred
      t.bigint :depth                                # queue depth, where applicable
      t.float  :throughput                           # completed units per second
      t.float  :drain_seconds                        # depth / throughput
      t.json   :metrics                              # the full measured reading

      t.index :sampled_at
      t.index [ :dependency, :subject, :sampled_at ], name: "index_observatory_dependency_samples_on_subject"
    end
  end

  # One deployment, so a regression can be attributed to a release.
  #
  # @return [void]
  #
  def create_deployments
    create_table :observatory_deployments do |t|
      t.string   :release, null: false, limit: 64
      t.datetime :deployed_at, null: false, precision: 6
      t.string   :branch, limit: 128
      t.string   :schema_version, limit: 32
      t.string   :hostname, limit: 64
      t.string   :ruby_version, limit: 16
      t.string   :rails_version, limit: 16
      t.string   :environment, limit: 16
      t.json     :details

      t.timestamps

      t.index :release, unique: true
      t.index :deployed_at
    end
  end

  # One supervisor or watchdog action, with the application state that surrounded
  # it — which is what makes "the process was saturated, not dead" provable after
  # the fact.
  #
  # @return [void]
  #
  def create_watchdog_events
    create_table :observatory_watchdog_events do |t|
      t.datetime :occurred_at, null: false, precision: 6
      t.string   :hostname, null: false, limit: 64
      t.string   :service, null: false, limit: 32    # "web", "sidekiq-regular", …
      t.integer  :process_id
      t.integer  :worker_generation

      t.string  :trigger, null: false, limit: 64     # "health_check_failed", "memory", "fatal_log"
      t.integer :failed_probe_count
      t.float   :probe_duration_ms
      t.boolean :process_alive

      # The state at the moment of the decision.
      t.integer :busy_threads, limit: 2
      t.integer :max_threads, limit: 2
      t.integer :backlog
      t.integer :long_running_requests
      t.json    :long_running_summary

      # The decision itself, and what Observatory would have decided.
      t.string  :classification, null: false, limit: 32 # "process_death", "thread_saturation", …
      t.string  :action_taken, limit: 64
      t.string  :recommended_action, limit: 64
      t.string  :advisory_reason, limit: 500
      t.boolean :advisory_only, null: false, default: true
      t.string  :outcome, limit: 64

      t.string  :release, limit: 64
      t.bigint  :incident_id
      t.json    :evidence

      t.index :occurred_at
      t.index [ :service, :occurred_at ]
      t.index :incident_id
    end
  end

  # One detected incident: what is constrained, what is consuming it, and how
  # confident the engine is.
  #
  # @return [void]
  #
  def create_incidents
    create_table :observatory_incidents do |t|
      t.string   :fingerprint, null: false, limit: 64 # dedupes a continuing incident
      t.string   :rule, null: false, limit: 64
      t.string   :title, null: false, limit: 255
      t.string   :severity, null: false, limit: 16
      t.string   :status, null: false, limit: 16, default: "open"
      t.datetime :started_at, null: false, precision: 6
      t.datetime :ended_at, precision: 6
      t.datetime :last_seen_at, null: false, precision: 6

      t.string  :component, limit: 64                # "puma", "mysql", "sidekiq", …
      t.string  :constrained_resource, limit: 64     # "request_threads", "connections", …
      t.string  :primary_contributor, limit: 255     # the route or job class
      t.string  :failure_mode, limit: 255
      t.string  :confidence, null: false, limit: 16
      t.text    :impact
      t.text    :recommended_action
      t.text    :resolution_notes

      t.integer :occurrence_count, null: false, default: 1
      t.string  :release, limit: 64
      t.bigint  :deployment_id
      t.json    :summary

      t.timestamps

      t.index [ :fingerprint, :status ]
      t.index :started_at
      t.index [ :status, :severity, :started_at ]
    end
  end

  # One piece of evidence attached to an incident.
  #
  # Evidence is stored *for* and *against*, because a conclusion supported only
  # by confirming evidence is an assertion. The contradicting rows are what let
  # the dashboard say "MySQL connections were far below the configured maximum"
  # in the same breath as "the application is database-bound in appearance only".
  #
  # @return [void]
  #
  def create_incident_evidence
    create_table :observatory_incident_evidence do |t|
      t.bigint   :incident_id, null: false
      t.string   :stance, null: false, limit: 16     # "supporting" or "contradicting"
      t.integer  :position, null: false, default: 0
      t.string   :label, null: false, limit: 255
      t.string   :value, limit: 255
      t.string   :baseline, limit: 255
      t.string   :source, limit: 64                  # which measurement produced it
      t.datetime :observed_at, precision: 6
      t.string   :trace_kind, limit: 8
      t.bigint   :trace_row_id
      t.json     :details

      t.index [ :incident_id, :stance, :position ], name: "index_observatory_evidence_on_incident"
    end
  end

  # The measurements every execution carries, whatever its kind.
  #
  # @param table [ActiveRecord::ConnectionAdapters::TableDefinition] the table being defined.
  #
  # @return [void]
  #
  def add_execution_measurements(table)
    table.integer :query_count, null: false, default: 0
    table.integer :cached_query_count, null: false, default: 0
    table.integer :executed_query_count, null: false, default: 0
    table.integer :schema_query_count, null: false, default: 0
    table.integer :transaction_query_count, null: false, default: 0
    table.integer :async_query_count, null: false, default: 0
    table.float   :cached_query_ratio, null: false, default: 0.0
    table.float   :db_duration_ms, null: false, default: 0.0
    table.integer :row_count, null: false, default: 0
    table.integer :instantiation_count, null: false, default: 0
    table.integer :distinct_query_shapes, limit: 2, null: false, default: 0
    table.boolean :query_groups_truncated, null: false, default: false

    table.float   :view_duration_ms, null: false, default: 0.0
    table.integer :cache_read_count, null: false, default: 0
    table.integer :cache_hit_count, null: false, default: 0
    table.integer :cache_write_count, null: false, default: 0
    table.float   :cache_duration_ms, null: false, default: 0.0
    table.integer :external_call_count, null: false, default: 0
    table.float   :external_duration_ms, null: false, default: 0.0
    table.integer :external_error_count, null: false, default: 0
    table.json    :external_hosts
    table.float   :unaccounted_ms, null: false, default: 0.0

    # Estimates, and named as such: CRuby has no per-thread allocation counter,
    # so these are process-wide deltas contaminated by concurrent threads.
    table.bigint  :allocation_delta, null: false, default: 0
    table.bigint  :freed_delta, null: false, default: 0
    table.integer :gc_runs, null: false, default: 0
    table.integer :major_gc_runs, null: false, default: 0
    table.float   :estimated_gc_time_ms, null: false, default: 0.0

    table.integer :pool_size, limit: 2
    table.integer :pool_busy, limit: 2
    table.integer :pool_waiting, limit: 2

    table.string  :exception_class, limit: 255
    table.string  :exception_message, limit: 500
    table.json    :anomalies
    table.json    :retained_because
    table.string  :retention_class, null: false, limit: 16, default: "raw"

    table.integer :process_id
    table.bigint  :thread_id
    table.string  :hostname, limit: 64
    table.string  :release, limit: 64
    table.bigint  :incident_id
  end

  # The dimensions every rollup is keyed by.
  #
  # @param table [ActiveRecord::ConnectionAdapters::TableDefinition] the table being defined.
  #
  # @return [void]
  #
  def add_rollup_dimensions(table)
    table.string   :granularity, null: false, limit: 8, default: "minute"
    table.datetime :bucket_at, null: false
    table.string   :release, null: false, limit: 64, default: ""
  end

  # The aggregates every rollup carries.
  #
  # `duration_histogram` holds fixed log-spaced buckets, which is what makes p50,
  # p95 and p99 derivable without storing a row per request — and derivable from
  # *every* request rather than only the sampled ones.
  #
  # @param table [ActiveRecord::ConnectionAdapters::TableDefinition] the table being defined.
  #
  # @return [void]
  #
  def add_rollup_measurements(table)
    table.integer :count, null: false, default: 0
    table.float   :duration_sum_ms, null: false, default: 0.0
    table.float   :duration_max_ms, null: false, default: 0.0
    table.json    :duration_histogram

    table.bigint  :query_count_sum, null: false, default: 0
    table.integer :query_count_max, null: false, default: 0
    table.bigint  :cached_query_count_sum, null: false, default: 0
    table.bigint  :executed_query_count_sum, null: false, default: 0
    table.float   :db_duration_sum_ms, null: false, default: 0.0
    table.float   :view_duration_sum_ms, null: false, default: 0.0

    table.bigint  :allocation_sum, null: false, default: 0
    table.float   :gc_time_sum_ms, null: false, default: 0.0

    table.integer :external_call_sum, null: false, default: 0
    table.float   :external_duration_sum_ms, null: false, default: 0.0

    table.integer :sampled_trace_count, null: false, default: 0
  end
end
