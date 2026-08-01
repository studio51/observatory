# frozen_string_literal: true

require "observatory/version"
require "observatory/configuration"
require "observatory/instrumentation"
require "observatory/safely"
require "observatory/clock"
require "observatory/call_site"
require "observatory/release"
require "observatory/capacity"
require "observatory/sql/fingerprint"
require "observatory/sql/query_group"
require "observatory/execution/base"
require "observatory/execution/request"
require "observatory/execution/job"
require "observatory/traffic/classifier"
require "observatory/traffic/client_identity"

# Causal observability for Rails.
#
# Observatory does not ask whether the infrastructure is alive. It asks whether
# useful work is flowing through it, where time is going, and which finite
# resource is running out. The difference shows up in the incident it was built
# for: CPU at 40%, MySQL idle, Redis at 7.6%, Sidekiq processing, every
# dashboard green — and every Puma request thread held by a route performing
# eighty-six thousand ActiveRecord lookups, 97% of them served by the query
# cache and therefore invisible to MySQL.
#
# ## Getting a value out of it
#
#   Observatory.config.enabled = false      # complete off switch
#   Observatory.current                     # the execution in progress, or nil
#   Observatory.annotate(:expensive_export) # flag the current execution
#
#   Observatory::Instrumentation.suppress { … } # do something uninstrumented
#
# ## The rules it holds itself to
#
# - It never blocks the monitored request on I/O.
# - Every buffer it owns has a ceiling.
# - It never instruments itself.
# - It fails open: an exception inside Observatory cannot fail the request.
#
module Observatory
  class << self

    # The active configuration.
    #
    # @return [Observatory::Configuration]
    #
    def config
      @config ||= Configuration.new
    end

    # Configure Observatory.
    #
    # Call once from an initializer. Environment overrides are applied after the
    # block, so `OBSERVATORY_ENABLED=0` always wins over anything set in code —
    # which is what makes the off switch trustworthy at three in the morning.
    #
    # @yieldparam config [Observatory::Configuration] the configuration to mutate.
    #
    # @return [Observatory::Configuration]
    #
    def configure
      yield(config) if block_given?
      config.apply_environment_overrides!

      config
    end

    # Whether Observatory should collect in this process.
    #
    # The single question every subscriber, middleware and probe asks first.
    #
    # @return [Boolean]
    #
    def enabled?
      config.enabled? && !Instrumentation.suppressed?
    end

    # The execution currently being measured, if any.
    #
    # @return [Observatory::Execution::Base, nil]
    #
    def current
      return nil unless defined?(Current)

      Current.execution
    end

    # Flag the execution in progress with an application-supplied label.
    #
    # The one hook application code is expected to call. Use it to mark a request
    # or job that is known to be doing something unusual, so it survives sampling
    # and is legible in the explorer:
    #
    #   Observatory.annotate(:full_library_rebuild)
    #
    # A no-op when nothing is being measured, so it is safe to call anywhere.
    #
    # @param label [Symbol, String] the annotation.
    #
    # @return [void]
    #
    def annotate(label)
      current&.flag(label.to_sym)

      nil
    end

    # Force the execution in progress to be retained regardless of sampling.
    #
    # @return [void]
    #
    def retain!
      annotate(:marked_for_retention)
    end

    # Observatory's own logger, kept separate from the application's.
    #
    # Its output is the Phase 1 deliverable in its own right: before any
    # dashboard exists, `log/observatory.log` already answers "which request did
    # eighty-six thousand lookups".
    #
    # @return [Logger]
    #
    def logger
      config.logger ||= default_logger
    end

    # The host application's root, used to render call sites relatively.
    #
    # @return [String, nil]
    #
    def root_path
      @root_path ||= (Rails.root.to_s if defined?(Rails) && Rails.respond_to?(:root) && Rails.root)
    end

    # This machine's hostname, resolved once.
    #
    # @return [String]
    #
    def hostname
      @hostname ||= Safely.call("hostname", fallback: "unknown") { Socket.gethostname }
    end

    # When this process booted, used to age process samples.
    #
    # @return [Time] UTC.
    #
    def booted_at
      @booted_at ||= Clock.wall
    end

    # The identity of the Sidekiq process, when running inside one.
    #
    # @return [String, nil] e.g. "hostname:12345", or nil outside Sidekiq.
    #
    def sidekiq_process_identity
      return nil unless defined?(::Sidekiq)

      @sidekiq_process_identity ||= Safely.call("sidekiq.identity") do
        ::Sidekiq.respond_to?(:server?) && ::Sidekiq.server? ? "#{hostname}:#{Process.pid}" : nil
      end
    end

    # Whether this process is a Sidekiq worker.
    #
    # @return [Boolean]
    #
    def sidekiq_server?
      defined?(::Sidekiq) && ::Sidekiq.respond_to?(:server?) && ::Sidekiq.server?
    end

    # Reset every memoised process-level value. Test-suite hygiene only.
    #
    # @return [void]
    #
    def reset!
      @config = nil
      @root_path = nil
      @hostname = nil
      @booted_at = nil
      @sidekiq_process_identity = nil

      Release.reset!
      Capacity.reset!
      Safely.reset!

      nil
    end

  private

    # A dedicated log file, so Observatory's diagnostics never dilute the
    # application's — and so an operator can `tail` one thing.
    #
    # @return [Logger]
    #
    def default_logger
      return Logger.new($stdout) unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

      Logger.new(Rails.root.join("log", "observatory.log"), 3, 50 * 1_024 * 1_024).tap do |logger|
        logger.level = Logger::INFO
        logger.progname = "observatory".freeze
      end
    rescue SystemCallError
      Logger.new($stdout)
    end
  end
end

# Loaded last: the engine's class body reads Observatory.config, which the module
# above has to have defined first.
#
require "observatory/engine" if defined?(::Rails::Engine)
