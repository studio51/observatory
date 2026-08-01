# frozen_string_literal: true

module Observatory

  # Turns a finished execution into the flat rows that get logged and stored.
  #
  # One execution produces one summary row plus a handful of query-group rows —
  # never one row per query. That ratio is the storage design in a sentence: the
  # request that performed 86,359 lookups costs one trace row and perhaps twelve
  # group rows, not 86,359 of anything.
  #
  # Serialising happens after the response has been sent, on the way into the
  # buffer, so its cost is off the request's critical path.
  #
  module Serializer
    module_function

    # Flatten a finished execution.
    #
    # @param execution [Observatory::Execution::Base] the finished execution.
    # @param decision [Observatory::Sampling::Decision::Result] why it was retained.
    #
    # @return [Hash{Symbol => Object}] a `:trace` row plus its `:query_groups`.
    #
    def call(execution, decision)
      case execution
      when Execution::Request then request(execution, decision)
      when Execution::Job     then job(execution, decision)
      else                         { kind: :unknown }
      end
    end

    # @param execution [Observatory::Execution::Request] the finished request.
    # @param decision [Observatory::Sampling::Decision::Result] why it was retained.
    #
    # @return [Hash{Symbol => Object}]
    #
    def request(execution, decision)
      {
        kind:         :request,
        query_groups: query_groups(execution),
        trace: common(execution, decision).merge(
          request_id:        execution.request_id,
          http_method:       execution.http_method,
          route:             execution.endpoint,
          controller:        execution.controller,
          action:            execution.action,
          status:            execution.status,
          response_bytes:    execution.response_bytes,
          queue_wait_ms:     execution.queue_wait_ms,
          health_check:      execution.health_check,
          traffic_class:     execution.traffic_class&.to_s,
          user_agent_family: Traffic::Classifier.family(execution.user_agent),
          client_id:         execution.client_id,
          concurrent_requests: execution.concurrent_at_start,
          peak_concurrency:  execution.peak_concurrency,
          thread_seconds:    execution.thread_seconds.round(4),
        ),
      }
    end

    # @param execution [Observatory::Execution::Job] the finished job.
    # @param decision [Observatory::Sampling::Decision::Result] why it was retained.
    #
    # @return [Hash{Symbol => Object}]
    #
    def job(execution, decision)
      {
        kind:         :job,
        query_groups: query_groups(execution),
        trace: common(execution, decision).merge(
          jid:              execution.jid,
          job_class:        execution.job_class,
          queue:            execution.queue,
          enqueued_at:      execution.enqueued_at,
          queue_latency_ms: execution.queue_latency_ms,
          retry_count:      execution.retry_count,
          batch_id:         execution.batch_id,
          result:           execution.result&.to_s,
          throttle_wait_ms: execution.throttle_wait_ms,
          lock_wait_ms:     execution.lock_wait_ms,
          sidekiq_process:  execution.sidekiq_process,
          worker_seconds:   execution.worker_seconds.round(4),
        ),
      }
    end

    # The measurements every execution carries, whatever its kind.
    #
    # @param execution [Observatory::Execution::Base] the finished execution.
    # @param decision [Observatory::Sampling::Decision::Result] why it was retained.
    #
    # @return [Hash{Symbol => Object}]
    #
    def common(execution, decision)
      gc = execution.gc_delta

      {
        trace_id:      execution.trace_id,
        started_at:    execution.started_at,
        duration_ms:   execution.duration_ms.to_f.round(3),
        endpoint:      execution.endpoint,

        query_count:             execution.query_count,
        cached_query_count:      execution.cached_query_count,
        executed_query_count:    execution.executed_query_count,
        schema_query_count:      execution.schema_query_count,
        transaction_query_count: execution.transaction_query_count,
        async_query_count:       execution.async_query_count,
        cached_query_ratio:      execution.cached_query_ratio.round(4),
        db_duration_ms:          execution.db_duration_ms.round(3),
        row_count:               execution.row_count,
        instantiation_count:     execution.instantiation_count,
        distinct_query_shapes:   execution.query_groups.size,
        query_groups_truncated:  execution.fingerprinting_truncated?,

        view_duration_ms:     execution.view_duration_ms.round(3),
        cache_read_count:     execution.cache_read_count,
        cache_hit_count:      execution.cache_hit_count,
        cache_write_count:    execution.cache_write_count,
        cache_duration_ms:    execution.cache_duration_ms.round(3),
        external_call_count:  execution.external_call_count,
        external_duration_ms: execution.external_duration_ms.round(3),
        external_error_count: execution.external_error_count,
        external_hosts:       execution.external_calls.keys,
        unaccounted_ms:       execution.unaccounted_ms.round(3),

        allocation_delta:     gc[:allocation_delta],
        freed_delta:          gc[:freed_delta],
        gc_runs:              gc[:gc_runs],
        major_gc_runs:        gc[:major_gc_runs],
        estimated_gc_time_ms: gc[:estimated_gc_time_ms],

        pool_size:            execution.pool_stat&.dig(:size),
        pool_busy:            execution.pool_stat&.dig(:busy),
        pool_waiting:         execution.pool_stat&.dig(:waiting),

        exception_class:   execution.exception_class,
        exception_message: execution.exception_message,
        anomalies:         execution.anomalies.map(&:to_s),
        retained_because:  decision.reasons.map(&:to_s),
        retention_class:   decision.retention_class.to_s,

        process_id: execution.process_id,
        thread_id:  execution.thread_id,
        hostname:   execution.hostname,
        release:    execution.release,
      }
    end

    # The execution's query groups, largest first, ready for insertion.
    #
    # Ordered by count so that truncation — should a downstream consumer impose
    # its own limit — always drops the least interesting shapes first.
    #
    # @param execution [Observatory::Execution::Base] the finished execution.
    #
    # @return [Array<Hash{Symbol => Object}>]
    #
    def query_groups(execution)
      execution.query_groups.each_value.sort_by { |group| -group.count }.map(&:to_h)
    end
  end
end
