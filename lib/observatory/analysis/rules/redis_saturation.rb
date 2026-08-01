# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # Redis is actually constrained.
      #
      # ## Four signals, together, or nothing
      #
      # The easy mistake with Redis is to read a slowlog, find a handful of slow
      # commands, and declare it the culprit. A slowlog is a capped ring of the
      # worst commands ever seen — it will contain entries on a completely idle
      # server, and reasoning from it produces confident, wrong incidents.
      #
      # This rule refuses to fire on latency alone. It requires calculated
      # utilisation (command CPU over uptime), blocked clients, memory pressure
      # or rejected connections — measurements that describe *load*, not the
      # worst thing that happened once.
      #
      # The result is that during the incident this system was built for, Redis
      # is correctly reported as fine at 7.6%, and that number appears as
      # contradicting evidence on the finding that matters.
      #
      class RedisSaturation < Rule
        HIGH_UTILISATION = 0.70
        HIGH_MEMORY = 0.85

        # @return [Symbol]
        #
        def key = :redis_saturation

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          sample = window.latest_dependency(DependencySample::REDIS)
          return [] if sample.nil?

          reasons = pressure_signals(sample)
          return [] if reasons.empty?

          [ build_finding(sample, reasons) ]
        end

      private

        # Measurements that genuinely indicate load.
        #
        # @param sample [Observatory::DependencySample] the newest reading.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def pressure_signals(sample)
          signals = []

          if sample.utilisation.to_f >= HIGH_UTILISATION
            signals << evidence_for("Redis utilisation", percentage(sample.utilisation),
                                    baseline: "under #{percentage(HIGH_UTILISATION)}",
                                    observed_at: sample.sampled_at)
          end

          blocked = sample.metric("blocked_clients").to_i
          signals << evidence_for("Blocked clients", blocked, baseline: "0") if blocked.positive?

          rejected = sample.metric("rejected_connections").to_i
          signals << evidence_for("Rejected connections", rejected, baseline: "0") if rejected.positive?

          used = sample.metric("used_memory_bytes").to_i
          maximum = sample.metric("max_memory_bytes").to_i
          if maximum.positive? && (used.to_f / maximum) >= HIGH_MEMORY
            signals << evidence_for("Memory in use", percentage(used.to_f / maximum),
                                    baseline: "under #{percentage(HIGH_MEMORY)}")
          end

          evicted = sample.metric("evicted_keys").to_i
          signals << evidence_for("Evicted keys", count(evicted)) if evicted.positive?

          signals
        end

        # @param sample [Observatory::DependencySample] the newest reading.
        # @param reasons [Array<Observatory::Analysis::Evidence>] the pressure signals.
        #
        # @return [Observatory::Analysis::Finding]
        #
        def build_finding(sample, reasons)
          finding(
            title:      "Redis is under pressure",
            severity:   sample.utilisation.to_f >= 0.9 ? :critical : :warning,
            confidence: :high,
            component:  "redis",
            constrained_resource: "redis capacity",
            failure_mode: "Redis is doing enough work, or holding enough memory, that commands are queueing " \
                          "behind it. Sidekiq, the cache, uniqueness locks and throttling all share it.",
            impact: "Anything that touches Redis waits, which in this application means job enqueueing, " \
                    "fragment caching and rate limiting.",
            recommended_action: "Identify the command mix from INFO commandstats before changing anything.",
            started_at: sample.sampled_at,
            supporting: reasons,
            contradicting: [
              evidence_against("Slow commands per hour", sample.metric("slow_commands_per_hour"),
                               details: { note: "a slowlog is a capped ring of the worst commands ever " \
                                                "seen, not a measure of current load" }),
              evidence_against("Keyspace hit ratio", percentage(sample.metric("keyspace_hit_ratio"))),
              evidence_against("Connected clients",
                               "#{sample.metric("connected_clients")} of #{sample.metric("max_clients")}"),
            ],
            subjects: { dependency_samples: [ sample.id ] },
          )
        end
      end
    end
  end
end
