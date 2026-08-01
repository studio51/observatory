# frozen_string_literal: true

module Observatory

  # Owns Observatory's background threads and their lifecycle.
  #
  # There are exactly two: the {Pipeline::Writer}, which drains the event buffer
  # into the database, and the {Sampler}, which takes periodic readings of Puma,
  # Sidekiq, MySQL, Redis and the process itself and flushes the minute rollups.
  #
  # ## Where threads may and may not be started
  #
  # Not at load time, and not in the Puma master. This application runs
  # `preload_app!` with three workers: a thread created before `fork` does not
  # exist in the child, and does not announce its absence. Observatory therefore
  # starts from three places, all of which are after any fork:
  #
  # - `config.after_initialize` — covers development, tests, console and Sidekiq;
  # - `on_worker_boot` in `config/puma.rb` — covers clustered Puma workers;
  # - the writer's own pid guard — catches anything the first two miss.
  #
  # Rake tasks and migrations deliberately start nothing. A `db:migrate` that
  # spawns a writer thread and then holds the process open at exit is a bad
  # surprise, and a one-shot task has nothing worth sampling.
  #
  module Runtime
    RAKE_EXEMPT = %w[observatory:].freeze

    class << self

      # Start the background threads for this process.
      #
      # Idempotent, so calling it from both `after_initialize` and
      # `on_worker_boot` is safe and is in fact the intended arrangement.
      #
      # @return [Boolean] whether anything is now running.
      #
      def start!
        return false unless Observatory.config.enabled?
        return false if rake_task?

        Safely.call("runtime.start", fallback: false) do
          Deployment.record! if Observatory.config.persist?

          Pipeline::Writer.start!
          Sampler.start!

          true
        end
      end

      # Stop the background threads, draining anything buffered first.
      #
      # @return [void]
      #
      def stop!
        Safely.call("runtime.stop") do
          Sampler.stop!
          Pipeline::Writer.stop!
        end

        nil
      end

      # Whether the background threads are running in this process.
      #
      # @return [Boolean]
      #
      def running?
        Pipeline::Writer.running? || Sampler.running?
      end

      # Everything an operator needs to answer "is monitoring itself healthy?".
      #
      # Rendered on the dashboard's diagnostics panel. A monitoring system that
      # is quietly broken while still looking installed is its own outage, so
      # these numbers are shown rather than assumed.
      #
      # @return [Hash{Symbol => Object}]
      #
      def health
        {
          enabled:      Observatory.config.enabled?,
          persisting:   Observatory.config.persist?,
          writer:       Pipeline::Writer.stats,
          sampler:      Sampler.stats,
          aggregator:   Pipeline::Aggregator.stats,
          failures:     Safely.failure_counts,
          release:      Release.current,
          process_id:   Process.pid,
          hostname:     Observatory.hostname,
        }
      end

      # Whether this process is running a rake task rather than serving work.
      #
      # Observatory's own tasks are exempt — `observatory:sweep` needs the models
      # but not the threads, and `observatory:demo` needs both.
      #
      # @return [Boolean]
      #
      def rake_task?
        return false unless defined?(::Rake) && ::Rake.respond_to?(:application)
        return false unless ::Rake.application.top_level_tasks.any?

        ::Rake.application.top_level_tasks.none? { |task| RAKE_EXEMPT.any? { |prefix| task.start_with?(prefix) } }
      rescue StandardError
        false
      end
    end
  end
end
