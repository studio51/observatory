# frozen_string_literal: true

module Observatory
  module Pipeline

    # Per-minute rollups, accumulated in memory and flushed periodically.
    #
    # ## Why rollups see everything and traces do not
    #
    # Traces are sampled — at 1%, keeping only what is remarkable. That is right
    # for "show me the request that did 86,000 lookups" and completely wrong for
    # "how many requests did this route serve?". Extrapolating a rate from a 1%
    # sample of a skewed distribution produces confident nonsense.
    #
    # So **every** execution updates a rollup, sampled or not. The counts here
    # are true counts; only the linked traces are a sample. Each rollup records
    # `sampled_trace_count` alongside `count` so the dashboard can say which is
    # which.
    #
    # ## Cost
    #
    # One hash lookup and a handful of integer additions per execution, on the
    # thread that just finished the work. No I/O. The accumulator is flushed by
    # the sampler thread once a minute, which is when the only database contact
    # happens.
    #
    # ## Bounded, like everything else
    #
    # A 404 flood or a pathological number of distinct endpoints could otherwise
    # grow the accumulator without limit. Past `MAX_BUCKETS` new keys fold into a
    # single `(other)` bucket, which keeps the memory fixed and is visible in the
    # dashboard rather than silent.
    #
    module Aggregator
      MAX_BUCKETS = 2_000
      OTHER       = "(other)".freeze

      @mutex   = Mutex.new
      @routes  = {}
      @jobs    = {}
      @folded  = 0

      class << self

        # Fold a finished execution into its minute bucket.
        #
        # @param execution [Observatory::Execution::Base] the finished execution.
        # @param retained [Boolean] whether its trace was kept by the sampler.
        #
        # @return [void]
        #
        def record(execution, retained: false)
          Safely.call("pipeline.aggregator.record") do
            case execution
            when Execution::Request then record_request(execution, retained)
            when Execution::Job     then record_job(execution, retained)
            end
          end

          nil
        end

        # Write every complete bucket to the database and forget it.
        #
        # The current minute is left alone so it is not written half-finished and
        # then written again; only buckets strictly older than `now`'s minute are
        # flushed.
        #
        # @param now [Time] the current time, injectable for tests.
        #
        # @return [Integer] buckets written.
        #
        def flush!(now: Clock.wall)
          boundary = now.change(sec: 0, usec: 0)
          routes, jobs = take_complete_buckets(boundary)
          return 0 if routes.empty? && jobs.empty?

          Safely.call("pipeline.aggregator.flush", fallback: 0) do
            Instrumentation.suppress do
              upsert(RouteRollup, routes.values, %i[granularity bucket_at endpoint release]) +
                upsert(JobRollup, jobs.values, %i[granularity bucket_at job_class queue release])
            end
          end
        end

        # How many buckets are waiting to be written.
        #
        # @return [Hash{Symbol => Integer}]
        #
        def stats
          @mutex.synchronize { { route_buckets: @routes.size, job_buckets: @jobs.size, folded: @folded } }
        end

        # Discard everything. Test-suite hygiene only.
        #
        # @return [void]
        #
        def reset!
          @mutex.synchronize do
            @routes.clear
            @jobs.clear
            @folded = 0
          end

          nil
        end

      private

        # @param execution [Observatory::Execution::Request] the finished request.
        # @param retained [Boolean] whether its trace was kept.
        #
        # @return [void]
        #
        def record_request(execution, retained)
          key = [ minute_of(execution.started_at), execution.endpoint, execution.release.to_s ]

          @mutex.synchronize do
            bucket = bucket_for(@routes, key) do
              base_bucket.merge(
                granularity: RouteRollup::MINUTE, bucket_at: key[0], endpoint: key[1], release: key[2],
                error_count: 0, crawler_count: 0, thread_seconds: 0.0, response_bytes_sum: 0,
              )
            end

            accumulate(bucket, execution, retained)
            bucket[:error_count] += 1 if execution.error?
            bucket[:crawler_count] += 1 if Traffic::Classifier.automated?(execution.traffic_class)
            bucket[:thread_seconds] += execution.thread_seconds
            bucket[:response_bytes_sum] += execution.response_bytes.to_i
          end

          nil
        end

        # @param execution [Observatory::Execution::Job] the finished job.
        # @param retained [Boolean] whether its trace was kept.
        #
        # @return [void]
        #
        def record_job(execution, retained)
          key = [ minute_of(execution.started_at), execution.job_class.to_s, execution.queue.to_s,
                  execution.release.to_s, ]

          @mutex.synchronize do
            bucket = bucket_for(@jobs, key) do
              base_bucket.merge(
                granularity: JobRollup::MINUTE, bucket_at: key[0], job_class: key[1], queue: key[2],
                release: key[3], failure_count: 0, retry_count: 0, worker_seconds: 0.0,
                queue_latency_sum_ms: 0.0, queue_latency_max_ms: 0.0,
              )
            end

            accumulate(bucket, execution, retained)
            bucket[:failure_count] += 1 if execution.error?
            bucket[:retry_count] += execution.retry_count.to_i
            bucket[:worker_seconds] += execution.worker_seconds

            latency = execution.queue_latency_ms.to_f
            bucket[:queue_latency_sum_ms] += latency
            bucket[:queue_latency_max_ms] = latency if latency > bucket[:queue_latency_max_ms]
          end

          nil
        end

        # The measurements every rollup accumulates, whatever the execution kind.
        #
        # @param bucket [Hash] the bucket to update, mutated in place.
        # @param execution [Observatory::Execution::Base] the finished execution.
        # @param retained [Boolean] whether its trace was kept.
        #
        # @return [void]
        #
        def accumulate(bucket, execution, retained)
          duration = execution.duration_ms.to_f
          gc = execution.gc_delta

          bucket[:count] += 1
          bucket[:sampled_trace_count] += 1 if retained
          bucket[:duration_sum_ms] += duration
          bucket[:duration_max_ms] = duration if duration > bucket[:duration_max_ms]
          Histogram.observe(bucket[:duration_histogram], duration)

          bucket[:query_count_sum] += execution.query_count
          bucket[:query_count_max] = execution.query_count if execution.query_count > bucket[:query_count_max]
          bucket[:cached_query_count_sum] += execution.cached_query_count
          bucket[:executed_query_count_sum] += execution.executed_query_count
          bucket[:db_duration_sum_ms] += execution.db_duration_ms
          bucket[:view_duration_sum_ms] += execution.view_duration_ms

          bucket[:allocation_sum] += gc[:allocation_delta].to_i
          bucket[:gc_time_sum_ms] += gc[:estimated_gc_time_ms].to_f

          bucket[:external_call_sum] += execution.external_call_count
          bucket[:external_duration_sum_ms] += execution.external_duration_ms

          nil
        end

        # The zeroed measurements shared by both rollup kinds.
        #
        # @return [Hash{Symbol => Object}]
        #
        def base_bucket
          {
            count: 0, sampled_trace_count: 0,
            duration_sum_ms: 0.0, duration_max_ms: 0.0, duration_histogram: Histogram.empty,
            query_count_sum: 0, query_count_max: 0, cached_query_count_sum: 0,
            executed_query_count_sum: 0, db_duration_sum_ms: 0.0, view_duration_sum_ms: 0.0,
            allocation_sum: 0, gc_time_sum_ms: 0.0,
            external_call_sum: 0, external_duration_sum_ms: 0.0,
          }
        end

        # Find or create a bucket, folding into `(other)` past the ceiling.
        #
        # Called with the mutex held.
        #
        # @param store [Hash] the accumulator to look in.
        # @param key [Array] the bucket key.
        #
        # @yield builds the bucket when it does not exist.
        #
        # @return [Hash] the bucket.
        #
        def bucket_for(store, key)
          existing = store[key]
          return existing if existing

          if store.size >= MAX_BUCKETS
            @folded += 1
            folded_key = key.dup
            folded_key[1] = OTHER

            return store[folded_key] ||= yield.merge(endpoint_key(store) => OTHER)
          end

          store[key] = yield
        end

        # @param store [Hash] the accumulator being folded into.
        #
        # @return [Symbol] the dimension that names the workload.
        #
        def endpoint_key(store)
          store.equal?(@routes) ? :endpoint : :job_class
        end

        # Remove and return every bucket older than the current minute.
        #
        # @param boundary [Time] the start of the current minute.
        #
        # @return [Array(Hash, Hash)] the route and job buckets taken.
        #
        def take_complete_buckets(boundary)
          @mutex.synchronize do
            routes = @routes.select { |key, _| key[0] < boundary }
            jobs   = @jobs.select { |key, _| key[0] < boundary }

            routes.each_key { |key| @routes.delete(key) }
            jobs.each_key { |key| @jobs.delete(key) }

            [ routes, jobs ]
          end
        end

        # Write buckets, adding to any row that already exists.
        #
        # Three Puma workers and two Sidekiq processes all flush their own view of
        # the same minute, so this must *add* rather than replace — otherwise the
        # last worker to flush would silently discard the other four's traffic.
        #
        # @param model [Class] the rollup model.
        # @param buckets [Array<Hash>] the buckets to write.
        # @param key_columns [Array<Symbol>] the unique key to merge on.
        #
        # @return [Integer] buckets written.
        #
        def upsert(model, buckets, key_columns)
          return 0 if buckets.empty?

          buckets.each do |bucket|
            row = bucket.dup
            conditions = row.slice(*key_columns)
            existing = model.find_by(conditions)

            if existing
              merge_into(existing, row).save!
            else
              model.create!(row)
            end
          rescue ActiveRecord::RecordNotUnique
            existing = model.find_by(conditions)
            merge_into(existing, row).save! if existing
          end

          buckets.size
        end

        # Add a bucket's measurements to an existing row.
        #
        # @param record [Observatory::Record] the row to update.
        # @param bucket [Hash] the bucket to add.
        #
        # @return [Observatory::Record] the updated, unsaved row.
        #
        def merge_into(record, bucket)
          bucket.each do |column, value|
            case column
            when :granularity, :bucket_at, :endpoint, :release, :job_class, :queue
              next
            when :duration_histogram
              record.duration_histogram = Histogram.merge(Array(record.duration_histogram), value)
            when :duration_max_ms, :query_count_max, :queue_latency_max_ms
              record[column] = value if value.to_f > record[column].to_f
            else
              record[column] = record[column].to_f + value.to_f if record.has_attribute?(column)
            end
          end

          record
        end

        # @param time [Time] a wall-clock time.
        #
        # @return [Time] the start of the minute it falls in.
        #
        def minute_of(time)
          time.change(sec: 0, usec: 0)
        end
      end
    end
  end
end
