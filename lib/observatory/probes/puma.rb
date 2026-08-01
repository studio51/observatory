# frozen_string_literal: true

module Observatory
  module Probes

    # Reads Puma's request capacity — the finite resource this whole product is
    # organised around.
    #
    # ## Why this is three layers and not one call
    #
    # `Puma.stats_hash` looks like the obvious answer and is the wrong one in a
    # clustered deployment. Reading Puma 8.0.2's source rather than its API name:
    #
    # - `Puma.stats_object` is assigned exactly once, in `Puma::Launcher#run`
    #   (`launcher.rb:110`), which runs in the **master**. A forked worker
    #   inherits that object, so calling `Puma.stats_hash` inside a worker returns
    #   *cluster* stats whose `worker_status` was snapshotted at fork time. It
    #   describes neither this worker's thread pool nor the cluster's current
    #   state.
    # - `Puma::ThreadPool#stats` **mutates**: it zeroes `@backlog_max`
    #   (`thread_pool.rb:143`), and `Server#stats` also calls `reset_max`. Whoever
    #   reads it steals the high-water mark from every other reader. Observatory
    #   must be the only caller, which the runbook records.
    #
    # So capacity is resolved through three layers, and every sample records
    # which one answered:
    #
    # 1. **`:server`** — the worker's own `Puma::Server`, located once per process
    #    by an `ObjectSpace` scan (see {server}). Authoritative: real busy-thread
    #    and backlog numbers for this worker.
    # 2. **`:stats_hash`** — `Puma.stats_hash`, used only when it actually returns
    #    thread-pool keys, which happens in single (development) mode.
    # 3. **`:in_flight`** — Observatory's own request register. Always available,
    #    exactly right about how many requests are inside the Rack application,
    #    and honest that it cannot see the backlog: `backlog` is reported as
    #    **nil**, meaning *unknown*, never as zero.
    #
    # That last distinction is not pedantry. "Backlog is zero" and "backlog is
    # unmeasurable" lead to opposite conclusions about whether a process is
    # saturated, and a monitoring system that confuses them is how a living
    # process gets restarted for being busy.
    #
    module Puma
      THREAD_POOL_KEYS = %i[backlog running pool_capacity busy_threads max_threads].freeze
      DEFAULT_MAX_THREADS = 5

      class << self

        # A capacity reading for this process.
        #
        # Never raises and never returns nil — a degraded reading is always better
        # than none, provided it says it is degraded.
        #
        # @return [Hash{Symbol => Object}] with a `:source` naming the layer that answered.
        #
        def sample
          from_server || from_stats_hash || from_in_flight
        end

        # The number of request threads this process can run.
        #
        # The denominator of every capacity figure, so it is resolved once and
        # cached: Puma's configured maximum when Puma is present and has told us,
        # otherwise `RAILS_MAX_THREADS`, otherwise Puma's own default of five.
        #
        # @return [Integer]
        #
        def configured_max_threads
          @configured_max_threads ||= Safely.call("probes.puma.max_threads", fallback: DEFAULT_MAX_THREADS) do
            from_server_max_threads || from_environment_max_threads || DEFAULT_MAX_THREADS
          end
        end

        # Whether this process is being served by Puma at all.
        #
        # @return [Boolean]
        #
        def present?
          defined?(::Puma) && !server.nil?
        end

        # This worker's index within the cluster, when it is a cluster worker.
        #
        # Set by the host's `config/puma.rb` through {worker_index=} in an
        # `on_worker_boot` hook — Puma passes the index to that hook and nothing
        # inside the worker can otherwise discover it.
        #
        # @return [Integer, nil]
        #
        attr_accessor :worker_index

        # Forget every memoised lookup. Test-suite hygiene only.
        #
        # @return [void]
        #
        def reset!
          @server = nil
          @server_looked_up = false
          @configured_max_threads = nil
          @worker_index = nil

          nil
        end

        # The `Puma::Server` running in this process, if there is one.
        #
        # ## The ObjectSpace scan, and why it is acceptable here
        #
        # Puma exposes no supported way for application code inside a worker to
        # reach its own `Server`. `ObjectSpace.each_object` will find it, at the
        # cost of a full heap walk — tens of milliseconds on a large application,
        # which would be indefensible on a request path.
        #
        # It is not on a request path. This runs **once per process**, from the
        # background sampler thread, and the result (including a negative result)
        # is memoised for the life of the process. The cost is one heap walk at
        # boot in exchange for real busy-thread and backlog numbers for the rest
        # of the process's life. It can be switched off entirely with
        # `puma_object_space_lookup = false`, in which case capacity degrades to
        # the in-flight register.
        #
        # @return [Puma::Server, nil]
        #
        def server
          return @server if @server_looked_up

          @server_looked_up = true
          @server = Safely.call("probes.puma.locate") { locate_server }
        end

      private

        # @return [Puma::Server, nil]
        #
        def locate_server
          return nil unless defined?(::Puma::Server)
          return nil unless Observatory.config.puma_object_space_lookup

          ObjectSpace.each_object(::Puma::Server).find { |candidate| candidate.respond_to?(:stats) }
        end

        # Layer 1: the worker's own server. Authoritative.
        #
        # @return [Hash, nil]
        #
        def from_server
          instance = server
          return nil if instance.nil?

          Safely.call("probes.puma.server_stats") do
            normalise(instance.stats, :server)
          end
        end

        # Layer 2: `Puma.stats_hash`, accepted only when it carries thread-pool
        # keys — which is to say, only in single mode, where the stats object is
        # the server.
        #
        # @return [Hash, nil]
        #
        def from_stats_hash
          return nil unless defined?(::Puma) && ::Puma.respond_to?(:stats_hash)

          Safely.call("probes.puma.stats_hash") do
            stats = ::Puma.stats_hash
            next nil unless stats.is_a?(Hash)
            next nil unless THREAD_POOL_KEYS.any? { |key| stats.key?(key) }

            normalise(stats, :stats_hash)
          end
        end

        # Layer 3: Observatory's own register. Always available; backlog unknown.
        #
        # @return [Hash]
        #
        def from_in_flight
          busy = Capacity.in_flight_count
          max  = configured_max_threads

          {
            source:        :in_flight,
            max_threads:   max,
            busy_threads:  busy,
            idle_threads:  [ max - busy, 0 ].max,
            running:       max,
            backlog:       nil,   # unknown, NOT zero — see the module docs
            backlog_max:   nil,
            pool_capacity: [ max - busy, 0 ].max,
            worker_index:  worker_index,
            saturated:     busy >= max,
            saturated_for: Capacity.saturated_for,
          }
        end

        # Fold a Puma stats hash into Observatory's shape, feature-detecting each
        # key so a future Puma that renames one degrades rather than raises.
        #
        # @param stats [Hash] Puma's stats.
        # @param source [Symbol] which layer produced them.
        #
        # @return [Hash{Symbol => Object}]
        #
        def normalise(stats, source)
          max  = stats[:max_threads] || configured_max_threads
          busy = stats[:busy_threads] || Capacity.in_flight_count

          {
            source:        source,
            max_threads:   max,
            busy_threads:  busy,
            idle_threads:  [ max - busy, 0 ].max,
            running:       stats[:running],
            backlog:       stats[:backlog],
            backlog_max:   stats[:backlog_max],
            pool_capacity: stats[:pool_capacity],
            requests_count: stats[:requests_count],
            worker_index:  worker_index,
            saturated:     busy >= max && stats[:backlog].to_i.positive?,
            saturated_for: Capacity.saturated_for,
          }
        end

        # @return [Integer, nil] Puma's configured maximum, when the server is reachable.
        #
        def from_server_max_threads
          instance = server
          return nil if instance.nil?
          return nil unless instance.respond_to?(:max_threads)

          instance.max_threads
        end

        # @return [Integer, nil] the value `config/puma.rb` derives its thread count from.
        #
        def from_environment_max_threads
          raw = ENV["RAILS_MAX_THREADS"]
          return nil if raw.nil? || raw.empty?

          value = raw.to_i

          value.positive? ? value : nil
        end
      end
    end
  end
end
