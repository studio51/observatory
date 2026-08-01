# frozen_string_literal: true

module Observatory
  module Sampling

    # Decides, at completion, whether an execution is worth keeping.
    #
    # **Tail-based**, not head-based, and the distinction is the whole point. A
    # head-based sampler chooses before the work happens, so at a 1% rate it
    # keeps the fourteen-second, eighty-six-thousand-query request with 1%
    # probability — which means the incident that matters is, ninety-nine times
    # in a hundred, simply absent from the data. Deciding at the tail means the
    # request has already told us what it did, and anything remarkable is kept
    # with certainty.
    #
    # So the rule is: **keep everything interesting, sample only the boring.**
    #
    # A retained trace also carries *why* it was retained, which is what lets the
    # explorer say "kept because: query-count threshold" instead of leaving an
    # operator to guess whether the absence of a trace means the request was fine
    # or merely unlucky.
    #
    module Decision

      # The outcome of a sampling decision.
      #
      Result = Struct.new(
        :keep,             # Boolean: whether to retain the execution
        :reasons,          # Array<Symbol>: every rule that voted to keep it
        :retention_class,  # Symbol: :error, :anomalous or :raw — drives how long it is kept
      ) do
        # @return [Boolean] whether the execution should be retained.
        #
        def keep?
          keep
        end
      end

      DROP = Result.new(false, [].freeze, :raw).freeze

      class << self

        # Decide whether to retain a completed execution.
        #
        # @param execution [Observatory::Execution::Base] the finished execution.
        # @param config [Observatory::Configuration] thresholds to apply.
        #
        # @return [Observatory::Sampling::Decision::Result]
        #
        def call(execution, config = Observatory.config)
          reasons = always_keep_reasons(execution, config)

          return Result.new(true, reasons, retention_class(execution, reasons)) if reasons.any?
          return Result.new(true, [ :reservoir ], :raw) if reservoir_due?(execution)
          return Result.new(true, [ :sampled ], :raw) if sampled?(execution, config)

          DROP
        end

        # Forget the per-route reservoir. Test-suite hygiene only.
        #
        # @return [void]
        #
        def reset!
          @reservoir = nil

          nil
        end

      private

        # Every reason this execution must be kept regardless of sampling.
        #
        # Note the deliberate alignment with the detection rules: the thresholds
        # here are the *same* configuration values the rule engine uses. That is
        # not a coincidence to be tidied away later — it is the invariant that
        # guarantees a trace which trips a rule was never dropped before the rule
        # could see it.
        #
        # @param execution [Observatory::Execution::Base] the finished execution.
        # @param config [Observatory::Configuration] thresholds to apply.
        #
        # @return [Array<Symbol>]
        #
        def always_keep_reasons(execution, config)
          reasons = []

          reasons << :exception if execution.exception_class
          reasons << :server_error if execution.error?
          reasons << :marked if execution.anomalies.include?(:marked_for_retention)
          reasons << :slow if execution.duration_ms.to_f >= (config.slow_request_threshold * 1_000.0)
          reasons << :query_count if execution.query_count >= config.high_query_count
          reasons << :allocations if execution.gc_delta[:allocation_delta].to_i >= config.high_allocation_count
          reasons << :gc_pressure if gc_pressure?(execution, config)
          reasons << :cached_query_explosion if cached_explosion?(execution, config)
          reasons << :repeated_fingerprint if repeated_fingerprint?(execution, config)
          reasons << :health_check_failure if health_check_failure?(execution)
          reasons << :saturation if saturated?(execution)

          reasons
        end

        # The composite condition this whole product exists to notice: a slow
        # request that issued an enormous number of lookups, most of them served
        # from the ActiveRecord query cache, while the database did comparatively
        # little.
        #
        # Any one of those signals alone is ordinary. Together they are the
        # signature of application code looping over queries — and, crucially, a
        # shape that leaves no trace whatsoever in database monitoring.
        #
        # @param execution [Observatory::Execution::Base] the finished execution.
        # @param config [Observatory::Configuration] thresholds to apply.
        #
        # @return [Boolean]
        #
        def cached_explosion?(execution, config)
          execution.query_count >= config.high_query_count &&
            execution.cached_query_ratio >= config.high_cached_query_ratio &&
            execution.duration_ms.to_f >= (config.slow_request_threshold * 1_000.0)
        end

        # @param execution [Observatory::Execution::Base] the finished execution.
        # @param config [Observatory::Configuration] thresholds to apply.
        #
        # @return [Boolean] whether one query shape repeated abnormally often.
        #
        def repeated_fingerprint?(execution, config)
          dominant = execution.dominant_query_group

          !dominant.nil? && dominant.count >= config.repeated_fingerprint_count
        end

        # @param execution [Observatory::Execution::Base] the finished execution.
        # @param config [Observatory::Configuration] thresholds to apply.
        #
        # @return [Boolean] whether estimated GC took a material share of the duration.
        #
        def gc_pressure?(execution, config)
          duration = execution.duration_ms.to_f
          return false if duration <= 0

          (execution.gc_delta[:estimated_gc_time_ms].to_f / duration) >= config.high_gc_time_ratio
        end

        # A failing or slow health check is always kept, because the question
        # "why did `/up` fail?" is unanswerable without the trace of the `/up`
        # that failed.
        #
        # @param execution [Observatory::Execution::Base] the finished execution.
        #
        # @return [Boolean]
        #
        def health_check_failure?(execution)
          return false unless execution.respond_to?(:health_check) && execution.health_check

          execution.status.to_i >= 400 || execution.duration_ms.to_f >= 1_000.0
        end

        # Whether this execution was running while its process had every request
        # thread occupied.
        #
        # @param execution [Observatory::Execution::Base] the finished execution.
        #
        # @return [Boolean]
        #
        def saturated?(execution)
          execution.respond_to?(:peak_concurrency) &&
            execution.peak_concurrency >= Capacity.max_threads
        end

        # Keep one trace per endpoint per interval, however dull.
        #
        # Without this, a 1% sample rate makes a route serving thirty requests an
        # hour invisible — and "no data" is indistinguishable from "no traffic".
        # The reservoir guarantees every live endpoint has a recent example.
        #
        # @param execution [Observatory::Execution::Base] the finished execution.
        #
        # @return [Boolean]
        #
        def reservoir_due?(execution)
          interval = Observatory.config.route_reservoir_interval.to_f
          return false if interval <= 0

          endpoint = execution.endpoint
          now = Clock.monotonic
          store = (@reservoir ||= {})
          last = store[endpoint]

          return false if last && (now - last) < interval

          # Bounded: an application with a pathological number of distinct
          # endpoints (or a 404 flood coarsened into many buckets) must not grow
          # this hash without limit.
          #
          store.clear if store.size > 5_000
          store[endpoint] = now

          true
        end

        # The ordinary random sample, applied only to executions nothing else
        # claimed.
        #
        # @param execution [Observatory::Execution::Base] the finished execution.
        # @param config [Observatory::Configuration] the rates to apply.
        #
        # @return [Boolean]
        #
        def sampled?(execution, config)
          rate = execution.is_a?(Execution::Job) ? config.normal_job_sample_rate : config.normal_request_sample_rate
          return false if rate <= 0
          return true if rate >= 1

          Kernel.rand < rate
        end

        # How long a retained execution should be kept.
        #
        # @param execution [Observatory::Execution::Base] the finished execution.
        # @param reasons [Array<Symbol>] why it was retained.
        #
        # @return [Symbol] :error, :anomalous or :raw.
        #
        def retention_class(execution, reasons)
          return :error if execution.exception_class || execution.error?
          return :anomalous if reasons.any?

          :raw
        end
      end
    end
  end
end
