# frozen_string_literal: true

module Observatory
  module Probes

    # Reads Redis's own counters and calculates utilisation from them.
    #
    # ## Utilisation is calculated, not inferred
    #
    # The common mistake is to look at a slowlog, find seven slow commands, and
    # conclude Redis is struggling. Seven slow commands an hour out of forty
    # million tells you nothing about load — it tells you that seven commands
    # were slow.
    #
    # Redis reports cumulative command CPU time and its own uptime, and the ratio
    # of the two *is* utilisation:
    #
    #   utilisation = used_cpu_sys + used_cpu_user / uptime_in_seconds
    #
    # That is how the dashboard can say "Redis utilisation: 7.6%, slow commands
    # ~7/hour, blocked clients 0 — not currently constrained" and be right, while
    # a slowlog-driven monitor is calling it out as the culprit.
    #
    # Worst-case latency and its *frequency* are both reported, because one slow
    # command matters very differently at seven an hour and seven a second.
    #
    module Redis
      INFO_SECTIONS = %w[server clients memory stats commandstats latencystats].freeze

      class << self

        # A measured snapshot of the Redis server.
        #
        # @return [Hash{Symbol => Object}, nil] nil when Redis is unreachable or disabled.
        #
        def sample
          return nil unless Observatory.config.redis_probe_enabled

          Safely.call("probes.redis.sample") do
            Instrumentation.suppress do
              info = fetch_info
              next nil if info.nil? || info.empty?

              build_sample(info)
            end
          end
        end

        # Forget the memoised connection. Test-suite hygiene only.
        #
        # @return [void]
        #
        def reset!
          @client = nil
          @client_looked_up = false

          nil
        end

      private

        # The Redis connection to probe.
        #
        # Sidekiq's pool is preferred because it is the busiest Redis in this
        # application and the one whose saturation would actually matter. The
        # probe borrows a connection from the existing pool rather than opening
        # its own, so it cannot add a connection during an incident caused by
        # running out of them.
        #
        # @yield [client] the Redis client, if one could be obtained.
        #
        # @return [Object, nil] the block's value, or nil when Redis is unavailable.
        #
        def with_client
          if defined?(::Sidekiq) && ::Sidekiq.respond_to?(:redis)
            return ::Sidekiq.redis { |client| yield(client) }
          end

          return nil unless defined?(::Redis)

          @client ||= ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))

          yield(@client)
        end

        # @return [Hash{String => String}, nil] the parsed INFO response.
        #
        def fetch_info
          with_client do |client|
            raw = client.info

            raw.is_a?(Hash) ? raw : parse_info(raw)
          end
        end

        # Parse a raw INFO string when the client does not do it for us.
        #
        # @param raw [String, nil] the INFO response.
        #
        # @return [Hash{String => String}]
        #
        def parse_info(raw)
          return {} if raw.nil?

          raw.to_s.each_line.with_object({}) do |line, parsed|
            next if line.start_with?("#") || !line.include?(":")

            key, value = line.strip.split(":", 2)
            parsed[key] = value
          end
        end

        # @param info [Hash{String => String}] the parsed INFO response.
        #
        # @return [Hash{Symbol => Object}]
        #
        def build_sample(info)
          uptime = info["uptime_in_seconds"].to_f
          cpu = info["used_cpu_sys"].to_f + info["used_cpu_user"].to_f
          hits = info["keyspace_hits"].to_i
          misses = info["keyspace_misses"].to_i

          {
            utilisation:        (uptime.positive? ? (cpu / uptime).round(4) : nil),
            uptime_seconds:     uptime.to_i,
            command_cpu_seconds: cpu.round(3),
            total_commands:     info["total_commands_processed"].to_i,
            commands_per_second: info["instantaneous_ops_per_sec"].to_i,
            connected_clients:  info["connected_clients"].to_i,
            blocked_clients:    info["blocked_clients"].to_i,
            max_clients:        info["maxclients"].to_i,
            used_memory_bytes:  info["used_memory"].to_i,
            used_memory_peak_bytes: info["used_memory_peak"].to_i,
            max_memory_bytes:   info["maxmemory"].to_i,
            memory_fragmentation: info["mem_fragmentation_ratio"].to_f,
            evicted_keys:       info["evicted_keys"].to_i,
            expired_keys:       info["expired_keys"].to_i,
            keyspace_hits:      hits,
            keyspace_misses:    misses,
            keyspace_hit_ratio: ((hits + misses).positive? ? (hits.to_f / (hits + misses)).round(4) : nil),
            rejected_connections: info["rejected_connections"].to_i,
            redis_version:      info["redis_version"],
            slow_commands_per_hour: slow_command_rate(uptime),
          }
        end

        # How often a command lands in the slowlog, per hour.
        #
        # A *rate*, deliberately, not a count. "Seven slow commands" is
        # meaningless; "seven an hour, against forty million commands" is a
        # verdict.
        #
        # @param uptime [Float] the server's uptime in seconds.
        #
        # @return [Float, nil] slow commands per hour.
        #
        def slow_command_rate(uptime)
          return nil unless uptime.positive?

          length = with_client { |client| client.call([ "SLOWLOG", "LEN" ]) }
          return nil if length.nil?

          # The slowlog is a capped ring (128 entries by default), so this is a
          # floor once it is full — which is why it is reported alongside
          # utilisation rather than on its own.
          #
          (length.to_f / (uptime / 3_600.0)).round(2)
        rescue StandardError
          nil
        end
      end
    end
  end
end
