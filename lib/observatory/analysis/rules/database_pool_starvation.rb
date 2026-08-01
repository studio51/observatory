# frozen_string_literal: true

module Observatory
  module Analysis
    module Rules

      # Application threads are waiting for a database connection.
      #
      # ## A different failure from a slow database
      #
      # Pool starvation and slow SQL both make requests slow and both involve the
      # database, and they need opposite responses. Slow SQL means the database
      # is working hard on something; starvation means threads are queueing for
      # permission to *ask*, while the database itself may be idle.
      #
      # This application makes starvation unlikely by construction — the pool is
      # 25 and a Puma worker has 5 threads — which is itself useful. When the
      # rule stays silent during an incident, "no connection checkout wait in
      # Rails" becomes a strong piece of contradicting evidence for the rules
      # that do fire, and it is one of the lines that keeps an operator away from
      # the database entirely.
      #
      class DatabasePoolStarvation < Rule

        # @return [Symbol]
        #
        def key = :database_pool_starvation

        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def call(window)
          waiting = window.process_samples.select { |sample| sample.pool_waiting.to_i.positive? }
          return [] if waiting.empty?

          [ build_finding(waiting, window) ]
        end

      private

        # @param waiting [Array<Observatory::ProcessSample>] samples showing threads waiting.
        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Observatory::Analysis::Finding]
        #
        def build_finding(waiting, window)
          worst = waiting.max_by { |sample| sample.pool_waiting.to_i }

          finding(
            title:      "Threads waiting for a database connection",
            severity:   worst.pool_waiting.to_i >= 5 ? :critical : :warning,
            confidence: :high,
            component:  "activerecord",
            constrained_resource: "database connections",
            primary_contributor:  window.dominant_route&.first,
            failure_mode: "The connection pool is exhausted, so threads block before they can issue a query. " \
                          "The database may be entirely idle while this happens.",
            impact: "Every waiting thread is a request or job making no progress and holding its slot.",
            recommended_action: "Compare the pool size against the thread count, and look for work holding a " \
                                "connection across an external call or a long computation.",
            started_at: waiting.map(&:sampled_at).min,
            supporting: [
              evidence_for("Threads waiting for a connection", worst.pool_waiting,
                           observed_at: worst.sampled_at),
              evidence_for("Connections checked out", "#{worst.pool_busy} of #{worst.pool_size}"),
              evidence_for("Processes affected", waiting.map(&:process_id).uniq.size),
            ],
            contradicting: contradicting(window),
            subjects: { process_samples: waiting.map(&:id) },
          )
        end

        # @param window [Observatory::Analysis::Window] the surrounding measurements.
        #
        # @return [Array<Observatory::Analysis::Evidence>]
        #
        def contradicting(window)
          mysql = window.latest_dependency(DependencySample::MYSQL)
          return [] if mysql.nil?

          [
            evidence_against("MySQL connections in use",
                             "#{mysql.metric("connections")} of #{mysql.metric("max_connections")}"),
            evidence_against("MySQL running threads", mysql.metric("running_threads")),
          ]
        end
      end
    end
  end
end
