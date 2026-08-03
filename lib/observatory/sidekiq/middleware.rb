# frozen_string_literal: true

module Observatory
  module Sidekiq

    # Sidekiq client and server middleware.
    #
    # The server half measures a job exactly as the Rack middleware measures a
    # request — same execution context, same query accounting, same query-cache
    # split, same fingerprinting. A job that performs 86,000 lookups is the same
    # bug as a request that does, and it should read the same way in the
    # dashboard.
    #
    # The client half stamps the enqueue time and propagates the correlation of
    # whatever enqueued the job, so a slow request that fans out into forty jobs
    # can be followed into them.
    #
    # ## Where it goes in the chain
    #
    # Outermost on the server side. This application already runs
    # `SidekiqUniqueJobs::Middleware::Server`, `SidekiqRequestStoreMiddleware` and
    # `NetworkBackoffMiddleware`, and each of those can *block* — a uniqueness
    # lock waits, a circuit breaker sleeps. Sitting outside them means the
    # measured duration includes that waiting, which is the honest number: a job
    # held for nine seconds by a lock occupied a worker thread for nine seconds
    # whether or not it was doing anything.
    #
    # ## Not instrumenting itself
    #
    # Any job under the `Observatory::` namespace is skipped outright. The
    # retention sweep runs as a job and issues hundreds of deletes; measuring it
    # would file a query explosion against Observatory every hour.
    #
    module Middleware
      ENQUEUED_AT = "enqueued_at".freeze
      CREATED_AT  = "created_at".freeze
      TRACE_KEY   = "observatory_parent_trace".freeze
      NAMESPACE   = "Observatory::".freeze

      # Server middleware: measures the job.
      #
      class Server
        include ::Sidekiq::ServerMiddleware if defined?(::Sidekiq::ServerMiddleware)

        # Measure one job.
        #
        # @param _worker [Object] the worker instance.
        # @param job [Hash] the job payload.
        # @param queue [String] the queue it came from.
        #
        # @yield runs the job.
        #
        # @return [Object] whatever the job returns.
        #
        def call(_worker, job, queue, &block)
          return yield unless Observatory.enabled?

          # Fail *open* on the skip decision too. This runs before the job does,
          # so anything raising here doesn't degrade monitoring — it destroys the
          # job being monitored, which is the one outcome this engine promises
          # never to cause.
          #
          return yield if Safely.call("sidekiq.server.internal", fallback: false) { Middleware.internal?(job) }

          context = Safely.call("sidekiq.server.start") { Middleware.build_context(job, queue) }
          return yield if context.nil?

          dispatch(context, &block)
        end

      private

        # Run the job with its context installed, closing it on every exit path.
        #
        # @param context [Observatory::Execution::Job] the context to install.
        #
        # @yield runs the job.
        #
        # @return [Object] whatever the job returns.
        #
        def dispatch(context)
          result = :success

          Current.with(context) do
            yield
          rescue Exception => exception # rubocop:disable Lint/RescueException
            result = :failure
            Safely.call("sidekiq.server.exception") { context.record_exception(exception) }

            raise
          ensure
            Safely.call("sidekiq.server.finish") do
              context.complete!(result:, pool_stat: Probes::Database.pool_stat)
              Pipeline.submit(context)
            end
          end
        end
      end

      # Client middleware: stamps enqueue time and correlation.
      #
      class Client
        include ::Sidekiq::ClientMiddleware if defined?(::Sidekiq::ClientMiddleware)

        # Annotate a job as it is pushed.
        #
        # @param _job_class [String, Class] the worker class.
        # @param job [Hash] the job payload, mutated in place.
        # @param _queue [String] the destination queue.
        # @param _redis_pool [Object] the connection pool being pushed to.
        #
        # @yield performs the push.
        #
        # @return [Object] whatever the push returns.
        #
        def call(_job_class, job, _queue, _redis_pool)
          return yield unless Observatory.enabled?

          Safely.call("sidekiq.client.push") do
            job[ENQUEUED_AT] ||= Time.now.to_f

            # Carry the enqueueing execution's trace id so a request that fans
            # out into jobs can be followed into them.
            #
            parent = Current.execution
            job[TRACE_KEY] = parent.trace_id if parent
          end

          yield
        end
      end

      class << self

        # Add both middlewares to Sidekiq's chains.
        #
        # Idempotent: Sidekiq's chain `add` replaces an existing entry of the same
        # class, and the engine may run this more than once in development where
        # initializers re-run on reload.
        #
        # @return [void]
        #
        def install!
          return unless defined?(::Sidekiq)

          ::Sidekiq.configure_server do |config|
            config.server_middleware { |chain| chain.prepend(Server) }
            config.client_middleware { |chain| chain.add(Client) }
          end

          ::Sidekiq.configure_client do |config|
            config.client_middleware { |chain| chain.add(Client) }
          end

          nil
        end

        # Whether a job belongs to Observatory itself.
        #
        # @param job [Hash] the job payload.
        #
        # @return [Boolean]
        #
        def internal?(job)
          job["class"].to_s.start_with?(NAMESPACE) ||
            wrapped_class(job).to_s.start_with?(NAMESPACE)
        end

        # Build the execution context for a job.
        #
        # @param job [Hash] the job payload.
        # @param queue [String] the queue it came from.
        #
        # @return [Observatory::Execution::Job]
        #
        def build_context(job, queue)
          Execution::Job.new(
            trace_id:    job[TRACE_KEY] || Trace.generate,
            jid:         job["jid"],
            job_class:   job_class_for(job),
            queue:       queue,
            enqueued_at: enqueued_at_for(job),
            retry_count: job["retry_count"].to_i,
            batch_id:    job["bid"],
          )
        end

        # The class that will actually run.
        #
        # ActiveJob wraps everything in `Sidekiq::JobWrapper`, so reporting the
        # `class` key would file every job in this application under one name. The
        # wrapped class is what an operator recognises.
        #
        # @param job [Hash] the job payload.
        #
        # @return [String]
        #
        def job_class_for(job)
          (wrapped_class(job) || job["class"]).to_s
        end

        # The wrapped class name an ActiveJob payload carries, if this is one.
        #
        # @param job [Hash] the job payload.
        #
        # @return [String, nil] the wrapped class name, or nil for a plain worker.
        #
        def wrapped_class(job)
          job["wrapped"] || active_job_payload(job)&.dig("job_class")
        end

        # The serialised ActiveJob payload, when the job is a wrapped one.
        #
        # ActiveJob's Sidekiq adapter puts a single Hash in `args`. A plain
        # `Sidekiq::Worker` puts its own positional arguments there instead, and
        # those are whatever the caller passed — an Integer id, a GlobalID
        # string, an Array. Reaching into `args[0]` with `dig` raises `TypeError`
        # on every one of them, so the type has to be established first rather
        # than assumed.
        #
        # @param job [Hash] the job payload.
        #
        # @return [Hash, nil] the ActiveJob payload, or nil for a plain worker.
        #
        def active_job_payload(job)
          first = job["args"].is_a?(Array) ? job["args"].first : nil

          first if first.is_a?(Hash)
        end

        # When the job was pushed.
        #
        # Sidekiq records `enqueued_at` on push and `created_at` on creation;
        # for a scheduled job they differ, and `enqueued_at` — when it actually
        # became runnable — is the one that makes queue latency mean anything.
        #
        # @param job [Hash] the job payload.
        #
        # @return [Time, nil]
        #
        def enqueued_at_for(job)
          raw = job[ENQUEUED_AT] || job[CREATED_AT]
          return nil if raw.nil?

          raw.is_a?(Numeric) ? Time.at(raw).utc : nil
        end
      end
    end
  end
end
