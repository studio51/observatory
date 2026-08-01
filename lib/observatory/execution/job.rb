# frozen_string_literal: true

module Observatory
  module Execution

    # One Sidekiq job, from the moment the worker picks it up to the moment it
    # returns or raises.
    #
    # Carries everything a request trace carries — query counts, cached ratio,
    # allocations, external calls — plus the two measurements that only make
    # sense for queued work: how long it sat in the queue before starting, and
    # how long it waited on a throttle or a uniqueness lock before running.
    #
    # Queue latency is the one that distinguishes "the queue is deep" from "the
    # queue is not draining". A 536,000-job queue with a two-second latency is
    # healthy; a 500-job queue with a nine-minute latency is not.
    #
    class Job < Base
      attr_reader :jid              # Sidekiq's job id
      attr_reader :job_class        # the worker class, or the wrapped ActiveJob class
      attr_reader :queue            # queue the job was pulled from
      attr_reader :enqueued_at      # when it was pushed
      attr_reader :queue_latency_ms # time between being pushed and starting
      attr_reader :retry_count      # attempts before this one
      attr_reader :batch_id         # parent batch, when the job belongs to one
      attr_reader :result           # :success, :failure or :interrupted
      attr_reader :throttle_wait_ms # time held back by a throttle, where observable
      attr_reader :lock_wait_ms     # time held back by a uniqueness lock, where observable
      attr_reader :sidekiq_process  # identity of the Sidekiq process that ran it
      attr_reader :pool_stat        # ActiveRecord connection-pool gauge at completion

      # @param trace_id [String] correlation id.
      # @param jid [String] Sidekiq's job id.
      # @param job_class [String] the class that will run.
      # @param queue [String] the queue it came from.
      # @param enqueued_at [Time, nil] when it was pushed, when Sidekiq records it.
      # @param retry_count [Integer] attempts already made.
      # @param batch_id [String, nil] parent batch identifier.
      #
      # @return [Observatory::Execution::Job]
      #
      def initialize(trace_id:, jid:, job_class:, queue:, enqueued_at: nil, retry_count: 0, batch_id: nil)
        super(trace_id:)

        @jid         = jid
        @job_class   = job_class
        @queue       = queue
        @enqueued_at = enqueued_at
        @retry_count = retry_count
        @batch_id    = batch_id
        @result      = nil
        @sidekiq_process = Observatory.sidekiq_process_identity

        @queue_latency_ms = enqueued_at && ((@started_at - enqueued_at) * 1_000.0).round(3)
      end

      # Record time the job spent held back before it could run.
      #
      # @param throttle_ms [Float, nil] milliseconds waiting on a throttle.
      # @param lock_ms [Float, nil] milliseconds waiting on a uniqueness lock.
      #
      # @return [void]
      #
      def record_wait(throttle_ms: nil, lock_ms: nil)
        @throttle_wait_ms = throttle_ms if throttle_ms
        @lock_wait_ms     = lock_ms if lock_ms

        nil
      end

      # Close the job with its outcome.
      #
      # @param result [Symbol] :success, :failure or :interrupted.
      # @param pool_stat [Hash, nil] ActiveRecord connection-pool gauge at completion.
      #
      # @return [self]
      #
      def complete!(result:, pool_stat: nil)
        @result    = result
        @pool_stat = pool_stat

        finish!
      end

      # A stable label for grouping and baselines.
      #
      # @return [String]
      #
      def endpoint
        @job_class
      end

      # Whether the job failed.
      #
      # Either an exception escaped (which `super` knows about) or the middleware
      # recorded a failure result.
      #
      # @return [Boolean]
      #
      def error?
        super || @result == :failure
      end

      # Worker-seconds this job consumed — the Sidekiq analogue of thread-seconds.
      #
      # @return [Float] seconds.
      #
      def worker_seconds
        thread_seconds
      end
    end
  end
end
