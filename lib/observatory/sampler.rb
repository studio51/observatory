# frozen_string_literal: true

module Observatory

  # The background thread that takes periodic readings and flushes rollups.
  #
  # Requests and jobs tell Observatory what *happened*. The sampler tells it what
  # *is* — how many Puma threads are busy right now, how deep the queues are, how
  # much of Redis is in use, whether MySQL is doing anything. Neither is
  # sufficient alone: the incident this system exists to explain is precisely the
  # one where the executions look expensive and every dependency looks idle, and
  # proving the second half requires having measured it.
  #
  # ## What it does each tick
  #
  # 1. Flush completed minute rollups (every process, cheap).
  # 2. Sample this process — Puma capacity, memory, GC, connection pool.
  # 3. Sample the shared dependencies — MySQL, Redis, Sidekiq — from **one**
  #    process only.
  #
  # That last division matters. Three Puma workers and two Sidekiq processes all
  # running `SHOW GLOBAL STATUS` and `INFO` every fifteen seconds would be five
  # times the probe load for one reading's worth of information, and the readings
  # are global anyway. A Redis-based lease elects one sampler; if it cannot be
  # taken, the process samples only itself.
  #
  # ## Cost
  #
  # Three `SHOW`-style statements and one `INFO` per interval, from one process,
  # all inside {Observatory::Instrumentation.suppress}. At the default
  # fifteen-second interval that is four queries a minute against a database
  # doing thousands a second.
  #
  module Sampler
    LEASE_KEY = "observatory:sampler:lease".freeze
    LEASE_MARGIN = 2   # lease outlives the interval so it does not lapse between ticks

    class << self

      # Start the sampler thread if it is not already running in this process.
      #
      # @return [Thread, nil]
      #
      def start!
        return nil unless Observatory.config.probes_enabled
        return @thread if running?

        @pid = ::Process.pid
        @stopping = false
        @thread = Thread.new { run }
        @thread.name = "observatory-sampler"
        @thread.abort_on_exception = false

        @thread
      end

      # Stop the sampler.
      #
      # @return [void]
      #
      def stop!
        @stopping = true
        @thread&.kill if @thread&.alive?
        @thread = nil

        nil
      end

      # Whether the sampler is running in *this* process.
      #
      # False after a fork, which is what makes the fork guard work.
      #
      # @return [Boolean]
      #
      def running?
        !@thread.nil? && @thread.alive? && @pid == ::Process.pid
      end

      # Take one reading now, on the calling thread.
      #
      # Exposed so the watchdog can capture evidence at the moment it is about to
      # act, rather than waiting up to fifteen seconds for the next tick — the
      # one moment when a stale reading would be worst.
      #
      # @return [Hash{Symbol => Object}] what was sampled.
      #
      def tick!
        Safely.call("sampler.tick", fallback: {}) do
          Instrumentation.suppress do
            Pipeline::Aggregator.flush!

            result = { process: sample_process }
            result.merge!(sample_dependencies) if lead_sampler?
            @ticks = @ticks.to_i + 1

            result
          end
        end
      end

      # How the sampler has been coping, for the diagnostics panel.
      #
      # @return [Hash{Symbol => Object}]
      #
      def stats
        {
          running:  running?,
          pid:      @pid,
          ticks:    @ticks.to_i,
          interval: Observatory.config.sample_interval,
          lead:     @lead_until.to_f > Clock.monotonic,
        }
      end

      # Forget all state. Test-suite hygiene only.
      #
      # @return [void]
      #
      def reset!
        @thread = nil
        @pid = nil
        @ticks = 0
        @lead_until = nil
        @stopping = false

        nil
      end

    private

      # The sampler loop.
      #
      # @return [void]
      #
      def run
        Instrumentation.suppress_thread!

        until @stopping
          sleep(Observatory.config.sample_interval)
          break if @stopping

          tick!
        end
      rescue Exception => exception # rubocop:disable Lint/RescueException
        Safely.call("sampler.crashed") { raise exception }
      end

      # Record this process's own state.
      #
      # @return [Observatory::ProcessSample, nil]
      #
      def sample_process
        capacity = Probes::Puma.sample
        process = Probes::Process.sample
        pool = Probes::Database.pool_stat || {}
        role = Observatory.sidekiq_server? ? ProcessSample::SIDEKIQ : ProcessSample::WEB

        return nil unless Observatory.config.persist?

        ProcessSample.create!(
          sampled_at:   Clock.wall,
          hostname:     Observatory.hostname,
          process_id:   ::Process.pid,
          role:         role,
          worker_index: capacity[:worker_index],

          capacity_source: capacity[:source].to_s,
          max_threads:     capacity[:max_threads],
          busy_threads:    capacity[:busy_threads],
          idle_threads:    capacity[:idle_threads],
          backlog:         capacity[:backlog],
          backlog_max:     capacity[:backlog_max],
          saturated:       capacity[:saturated] ? true : false,
          saturated_for_seconds: capacity[:saturated_for],

          rss_bytes:        process[:rss_bytes],
          cpu_seconds:      process[:cpu_seconds],
          allocated_objects: process[:allocated_objects],
          gc_count:         process[:gc_count],
          major_gc_count:   process[:major_gc_count],
          gc_total_time_ms: process[:gc_total_time_ms],
          heap_live_slots:  process[:heap_live_slots],
          heap_available_slots: process[:heap_available_slots],
          old_objects:      process[:old_objects],

          pool_size:    pool[:size],
          pool_busy:    pool[:busy],
          pool_waiting: pool[:waiting],

          release: Release.current,
          details: process.except(:rss_bytes, :cpu_seconds, :allocated_objects, :gc_count, :major_gc_count),
        )
      end

      # Record the shared dependencies. Runs in the lead sampler only.
      #
      # @return [Hash{Symbol => Object}]
      #
      def sample_dependencies
        return {} unless Observatory.config.persist?

        {
          mysql:   record_dependency(DependencySample::MYSQL, Probes::Database.server_sample),
          redis:   record_dependency(DependencySample::REDIS, Probes::Redis.sample),
          sidekiq: record_sidekiq(Probes::Sidekiq.sample),
        }
      end

      # @param dependency [String] which dependency this is.
      # @param metrics [Hash, nil] the measured reading.
      #
      # @return [Observatory::DependencySample, nil]
      #
      def record_dependency(dependency, metrics)
        return nil if metrics.nil? || metrics.empty?

        DependencySample.create!(
          sampled_at:  Clock.wall,
          dependency:  dependency,
          subject:     "",
          utilisation: metrics[:utilisation] || metrics[:connection_saturation],
          metrics:     metrics,
        )
      end

      # Record one row per Sidekiq queue plus one for the process set.
      #
      # Per-queue rather than one aggregate row because "the queue is deep" is
      # only ever a statement about a particular queue, and this application runs
      # eleven of them at different weights.
      #
      # @param sample [Hash, nil] a {Observatory::Probes::Sidekiq.sample} result.
      #
      # @return [Array<Observatory::DependencySample>]
      #
      def record_sidekiq(sample)
        return [] if sample.nil?

        rows = Array(sample[:queues]).map do |queue|
          DependencySample.create!(
            sampled_at:    Clock.wall,
            dependency:    DependencySample::SIDEKIQ,
            subject:       queue[:name],
            depth:         queue[:depth],
            throughput:    queue[:throughput],
            drain_seconds: finite(queue[:drain_seconds]),
            metrics:       queue,
          )
        end

        rows << DependencySample.create!(
          sampled_at: Clock.wall,
          dependency: DependencySample::SIDEKIQ,
          subject:    "",
          depth:      sample[:enqueued],
          throughput: sample[:throughput],
          metrics:    sample.except(:queues),
        )

        rows
      end

      # Whether this process should sample the shared dependencies this tick.
      #
      # A short Redis lease, renewed each tick, elects one sampler across every
      # Puma worker and Sidekiq process. Without Redis, every process samples —
      # noisier, but a monitoring system that stops measuring because it could
      # not coordinate would be worse.
      #
      # @return [Boolean]
      #
      def lead_sampler?
        return true if @lead_until.to_f > Clock.monotonic

        ttl = (Observatory.config.sample_interval * LEASE_MARGIN).ceil
        acquired = acquire_lease(ttl)
        @lead_until = Clock.monotonic + (ttl / 2.0) if acquired

        acquired
      end

      # @param ttl [Integer] lease duration in seconds.
      #
      # @return [Boolean] whether this process holds the lease.
      #
      def acquire_lease(ttl)
        return true unless defined?(::Sidekiq) && ::Sidekiq.respond_to?(:redis)

        identity = "#{Observatory.hostname}:#{::Process.pid}"

        ::Sidekiq.redis do |redis|
          # NX so only one process wins; the holder re-takes it each tick because
          # its own identity matches.
          #
          next true if redis.set(LEASE_KEY, identity, nx: true, ex: ttl)

          if redis.get(LEASE_KEY) == identity
            redis.expire(LEASE_KEY, ttl)

            next true
          end

          false
        end
      rescue StandardError
        true   # no coordination available; sample rather than go blind
      end

      # @param value [Float, nil] a possibly-infinite duration.
      #
      # @return [Float, nil] nil when infinite, so the column stays meaningful.
      #
      def finite(value)
        return nil if value.nil?
        return nil if value.respond_to?(:infinite?) && value.infinite?

        value
      end
    end
  end
end
