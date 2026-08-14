# frozen_string_literal: true

module Observatory

  # Every knob Observatory has, in one object.
  #
  # Defaults are chosen for a production Rails application and are deliberately
  # conservative: sampling is low, call-site capture is bounded, and every
  # buffer has a ceiling. Each attribute can be overridden in an initializer via
  # {Observatory.configure}, and most can be overridden per-deployment from the
  # environment (see {ENVIRONMENT_OVERRIDES}) so an operator can turn a knob on
  # a running box without shipping code.
  #
  # Reading a value is a plain attribute read on a frozen-in-practice object, so
  # it is safe on the hot path; nothing here does I/O.
  #
  class Configuration

    # Maps an environment variable to the attribute it overrides and the coercion
    # applied to its string value.
    # Only knobs that are safe and useful to change on a live box are listed —
    # notably the master switch, the sampling rates and the pipeline sizing.
    #
    ENVIRONMENT_OVERRIDES = {
      "OBSERVATORY_ENABLED"                    => [ :enabled, :boolean ],
      "OBSERVATORY_PERSIST"                    => [ :persist, :boolean ],
      "OBSERVATORY_LOG_EVENTS"                 => [ :log_events, :boolean ],
      "OBSERVATORY_NORMAL_REQUEST_SAMPLE_RATE" => [ :normal_request_sample_rate, :float ],
      "OBSERVATORY_NORMAL_JOB_SAMPLE_RATE"     => [ :normal_job_sample_rate, :float ],
      "OBSERVATORY_SLOW_REQUEST_THRESHOLD"     => [ :slow_request_threshold, :duration ],
      "OBSERVATORY_EXTREME_REQUEST_THRESHOLD"  => [ :extreme_request_threshold, :duration ],
      "OBSERVATORY_HIGH_QUERY_COUNT"           => [ :high_query_count, :integer ],
      "OBSERVATORY_EXTREME_QUERY_COUNT"        => [ :extreme_query_count, :integer ],
      "OBSERVATORY_HIGH_CACHED_QUERY_RATIO"    => [ :high_cached_query_ratio, :float ],
      "OBSERVATORY_HIGH_ALLOCATION_COUNT"      => [ :high_allocation_count, :integer ],
      "OBSERVATORY_CAPTURE_QUERY_CALL_SITES"   => [ :capture_query_call_sites, :boolean ],
      "OBSERVATORY_QUERY_CALL_SITE_THRESHOLD"  => [ :query_call_site_threshold, :integer ],
      "OBSERVATORY_BUFFER_CAPACITY"            => [ :buffer_capacity, :integer ],
      "OBSERVATORY_BATCH_SIZE"                 => [ :batch_size, :integer ],
      "OBSERVATORY_FLUSH_INTERVAL"             => [ :flush_interval, :float ],
      "OBSERVATORY_SAMPLE_INTERVAL"            => [ :sample_interval, :float ],
      "OBSERVATORY_ANALYSIS_ENABLED"           => [ :analysis_enabled, :boolean ],
    }.freeze

    # Path fragments that mark a backtrace frame as framework, gem or Observatory
    # code rather than the application's own.
    # A frame matching any of these is skipped when looking for the call site
    # that issued a repeated query.
    #
    DEFAULT_CALL_SITE_IGNORES = [
      "/gems/".freeze,
      "/ruby/".freeze,
      "/rubygems/".freeze,
      "/engines/observatory/".freeze,
      "<internal:".freeze,
    ].freeze

    # Request headers safe to store verbatim.
    # Anything carrying credentials, cookies or a raw address is excluded by
    # omission — this is an allowlist, so a header added upstream is never
    # captured until it is named here.
    #
    DEFAULT_CAPTURED_HEADERS = [
      "Accept".freeze,
      "Accept-Encoding".freeze,
      "Accept-Language".freeze,
      "Content-Type".freeze,
      "Turbo-Frame".freeze,
      "X-Requested-With".freeze,
    ].freeze

    # --- Master switches ---

    attr_accessor :enabled                     # false disables every subscriber, middleware and probe
    attr_accessor :persist                     # false collects and logs but never writes to the database
    attr_accessor :log_events                  # write each retained execution to the structured monitoring log
    attr_accessor :analysis_enabled            # run the detection rules over collected data
    attr_accessor :probes_enabled              # run the background sampler thread (Puma/Sidekiq/MySQL/Redis)
    attr_accessor :demo_enabled                # expose the development-only demonstration scenarios

    # --- Request sampling ---

    attr_accessor :normal_request_sample_rate  # 0.0-1.0 chance an unremarkable request is retained
    attr_accessor :normal_job_sample_rate      # 0.0-1.0 chance an unremarkable job is retained
    attr_accessor :route_reservoir_interval    # always keep one trace per route per this interval
    attr_accessor :ignored_paths               # request paths never traced (exact match or Regexp)
    attr_accessor :health_check_paths          # request paths treated as health checks, always retained

    # --- Anomaly thresholds ---
    #
    # These are the "is this worth keeping and worth flagging" thresholds. They
    # are read by both the sampler (retention) and the rule engine (detection),
    # so a trace that trips a rule is guaranteed to have been retained.

    attr_accessor :slow_request_threshold      # a request at/over this duration is always retained
    attr_accessor :extreme_request_threshold   # a request at/over this is severe on its own
    attr_accessor :slow_job_threshold          # a job at/over this duration is always retained
    attr_accessor :high_query_count            # ActiveRecord lookups in one execution
    attr_accessor :extreme_query_count         # lookups that are pathological on their own
    attr_accessor :high_cached_query_ratio     # 0.0-1.0 share served by the query cache
    attr_accessor :repeated_fingerprint_count  # one normalised fingerprint repeated this often
    attr_accessor :high_allocation_count       # estimated objects allocated during one execution
    attr_accessor :high_gc_time_ratio          # estimated GC time as a share of execution duration
    attr_accessor :slow_query_share            # share of duration one fingerprint must own to be "slow SQL"
    attr_accessor :puma_saturation_duration    # how long busy == max with a backlog before it is saturation
    attr_accessor :pool_wait_threshold         # connection checkout wait that counts as pool pressure
    attr_accessor :queue_drain_threshold       # estimated drain time above which a queue is regressing

    # --- Query analysis ---

    attr_accessor :max_query_groups            # distinct fingerprints kept per execution before folding
    attr_accessor :max_fingerprinted_queries   # stop normalising after this many queries in one execution
    attr_accessor :capture_query_call_sites    # collect a representative application call site at all
    attr_accessor :query_call_site_threshold   # repetitions of one fingerprint before a call site is taken
    attr_accessor :max_call_sites              # call sites captured per execution, total
    attr_accessor :call_site_depth             # stack frames examined when looking for application code
    attr_accessor :call_site_ignore_patterns   # path fragments that mark a frame as framework/gem code
    attr_accessor :representative_sql_length   # characters of redacted sample SQL kept per group

    # --- Pipeline ---

    attr_accessor :buffer_capacity             # events held in memory before low-value ones are dropped
    attr_accessor :batch_size                  # events written per database round trip
    attr_accessor :flush_interval              # seconds the writer waits before flushing a partial batch
    attr_accessor :writer_enabled              # run the background writer thread
    attr_accessor :synchronous                 # bypass the writer and persist inline (tests only)

    # --- Probes ---

    attr_accessor :sample_interval             # seconds between background dependency samples
    attr_accessor :mysql_probe_enabled         # run SHOW GLOBAL STATUS / information_schema queries
    attr_accessor :redis_probe_enabled         # run Redis INFO
    attr_accessor :puma_object_space_lookup    # allow the one-off ObjectSpace scan that finds Puma::Server

    # --- Retention ---

    attr_accessor :raw_trace_retention         # ordinary sampled traces
    attr_accessor :anomalous_trace_retention   # traces that tripped a threshold
    attr_accessor :error_trace_retention       # traces that raised or returned 5xx
    attr_accessor :rollup_retention            # minute rollups
    attr_accessor :daily_rollup_retention      # daily rollups
    attr_accessor :sample_retention            # process/dependency samples
    attr_accessor :incident_retention          # nil keeps incidents until deleted by hand

    # --- Privacy ---

    attr_accessor :client_id_secret            # HMAC key for anonymised client identifiers
    attr_accessor :client_id_rotation          # how often the HMAC salt rotates
    attr_accessor :captured_headers            # request headers stored verbatim (allowlist)
    attr_accessor :captured_query_params       # query-string parameters stored verbatim (allowlist)
    attr_accessor :store_raw_sql               # never store un-redacted SQL; here to be explicit

    # --- Reporting ---

    attr_accessor :logger                      # where Observatory's own diagnostics go
    attr_accessor :error_report_interval       # minimum seconds between identical internal error reports
    attr_accessor :release_resolver            # callable returning the active release identifier
    attr_accessor :parent_controller           # the host controller the dashboard inherits from, by name
    attr_accessor :deployment_marker_path      # file holding the deployed SHA, watched for changes
    attr_accessor :back_link_path              # host path the dashboard links back to; nil renders no link
    attr_accessor :back_link_label             # the label for that link

    # Build a configuration populated with the production-safe defaults.
    #
    # @return [Observatory::Configuration]
    #
    def initialize
      @enabled          = true
      @persist          = true
      @log_events       = true
      @analysis_enabled = true
      @probes_enabled   = true
      @demo_enabled     = false

      @normal_request_sample_rate = 0.01
      @normal_job_sample_rate     = 0.01
      @route_reservoir_interval   = 300  # seconds; keeps low-traffic routes observable
      @ignored_paths              = [ %r{\A/assets/}, %r{\A/vite/}, %r{\A/packs/}, %r{\A/cable\z} ]
      @health_check_paths         = [ "/up", "/heartbeat", "/healtcheck" ]

      @slow_request_threshold     = 1.0
      @extreme_request_threshold  = 10.0
      @slow_job_threshold         = 30.0
      @high_query_count           = 1_000
      @extreme_query_count        = 10_000
      @high_cached_query_ratio    = 0.80
      @repeated_fingerprint_count = 500
      @high_allocation_count      = 100_000
      @high_gc_time_ratio         = 0.10
      @slow_query_share           = 0.60
      @puma_saturation_duration   = 10.0
      @pool_wait_threshold        = 0.05
      # The drain estimate above which a backlog stops being acceptable. Four
      # hours, deliberately generous: this application routinely builds a
      # half-million-job queue during a full platform sync, and at 56 jobs a
      # second that clears in about two and a half hours with nothing wrong.
      # Both queue rules read this — below it and stable is classified healthy,
      # above it and rising is a regression — so one value keeps them from
      # contradicting each other.
      #
      @queue_drain_threshold      = 14_400.0

      @max_query_groups          = 200
      # Fingerprinting costs roughly 1.5 microseconds per query (measured; see
      # test/lib/observatory/performance/fingerprint_benchmark_test.rb), so the
      # 86,359-query incident pays about 130 ms of a 14-second request. The
      # ceiling exists for the genuinely unbounded case, not for that one — set
      # above it deliberately, so the incident this system was built to explain
      # is analysed at full fidelity rather than truncated.
      #
      @max_fingerprinted_queries = 100_000
      @capture_query_call_sites  = true
      @query_call_site_threshold = 100
      @max_call_sites            = 3
      @call_site_depth           = 30
      @call_site_ignore_patterns = DEFAULT_CALL_SITE_IGNORES
      @representative_sql_length = 500

      @buffer_capacity = 10_000
      @batch_size      = 250
      @flush_interval  = 1.0
      @writer_enabled  = true
      @synchronous     = false

      @sample_interval           = 15.0
      @mysql_probe_enabled       = true
      @redis_probe_enabled       = true
      @puma_object_space_lookup  = true

      @raw_trace_retention       = 86_400        # 24 hours
      @anomalous_trace_retention = 1_209_600     # 14 days
      @error_trace_retention     = 2_592_000     # 30 days
      @rollup_retention          = 7_776_000     # 90 days
      @daily_rollup_retention    = 31_536_000    # 1 year
      @sample_retention          = 1_209_600     # 14 days
      @incident_retention        = nil           # kept until deleted by hand

      @client_id_secret     = nil
      @client_id_rotation   = 86_400
      @captured_headers     = DEFAULT_CAPTURED_HEADERS
      @captured_query_params = []
      @store_raw_sql        = false

      @logger                 = nil
      @error_report_interval  = 60.0
      @release_resolver       = nil
      # Deliberately the bare Rails base. An unprotected monitoring dashboard
      # exposes route templates, query shapes and traffic patterns, so getting a
      # useful one should take an explicit decision by the host.
      #
      @parent_controller      = "ActionController::Base".freeze
      @deployment_marker_path = "tmp/pids/deploy.last-success".freeze

      # Where "back" goes is the host's business — it is the one link on the
      # dashboard that points out of the engine, and no route of the host's can
      # be assumed to exist. Unset, the link is simply not rendered.
      #
      @back_link_path  = nil
      @back_link_label = "← Back"
    end

    # Apply every {ENVIRONMENT_OVERRIDES} entry present in the given environment.
    #
    # Called once at boot, after the host's initializer block has run, so an
    # environment variable always wins over a value set in code.
    #
    # @param env [Hash] the environment to read, defaulting to the process's own.
    #
    # @return [Array<Symbol>] the attributes that were overridden.
    #
    def apply_environment_overrides!(env = ENV)
      ENVIRONMENT_OVERRIDES.filter_map do |variable, (attribute, type)|
        raw = env[variable]
        next if raw.nil? || raw.empty?

        public_send(:"#{attribute}=", coerce(raw, type))

        attribute
      end
    end

    # Whether Observatory should do anything at all in this process.
    #
    # Every subscriber, middleware and probe checks this first, so flipping it
    # false is a complete, immediate off switch that leaves the application
    # running normally.
    #
    # @return [Boolean]
    #
    def enabled?
      @enabled
    end

    # Whether collected executions should reach the database.
    # Collection and logging continue when this is false, which is the useful
    # shape for validating what is being measured before storing any of it.
    #
    # @return [Boolean]
    #
    def persist?
      @enabled && @persist
    end

    # The retention window, in seconds, for a trace of the given class.
    #
    # @param retention_class [Symbol] one of :error, :anomalous or :raw.
    #
    # @return [Integer] seconds to keep the trace for.
    #
    def retention_for(retention_class)
      case retention_class
      when :error     then @error_trace_retention
      when :anomalous then @anomalous_trace_retention
      else                 @raw_trace_retention
      end
    end

  private

    # Coerce an environment variable's string value to the type its attribute
    # expects.
    #
    # @param raw [String] the raw environment value.
    # @param type [Symbol] one of :boolean, :integer, :float or :duration.
    #
    # @return [Boolean, Integer, Float]
    #
    def coerce(raw, type)
      case type
      when :boolean  then !%w[0 false no off].include?(raw.strip.downcase)
      when :integer  then raw.to_i
      when :float,
           :duration then raw.to_f
      else                raw
      end
    end
  end
end
