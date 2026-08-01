# frozen_string_literal: true

require "json"

module Observatory

  # Classifies why a process is failing its health checks, and records the
  # evidence before anything restarts it.
  #
  # ## The problem, concretely
  #
  # `bin/dev`'s watchdog runs `curl -fsS -m 5 http://127.0.0.1:1337/up` every
  # thirty seconds and recycles Puma after three consecutive failures. From
  # outside a process, a dead master and a master whose fifteen request threads
  # are all held by fourteen-second requests are the same observation: curl times
  # out. The watchdog cannot tell them apart, so it restarts both.
  #
  # For the dead process that is correct. For the saturated one it drops every
  # in-flight request, changes nothing about the workload, and the condition
  # returns in ninety seconds — while the incident gets filed as "Puma crashed",
  # sending the next investigation somewhere useless.
  #
  # ## What this adds
  #
  # A view from *inside*. Observatory knows things curl cannot: whether workers
  # are still reporting samples, how many threads are busy, whether a backlog
  # exists, and which requests are holding the threads. That is enough to
  # separate the two cases with evidence rather than inference.
  #
  # ## Advisory only, deliberately
  #
  # {classify} returns a recommendation. It does not act, and `bin/dev` does not
  # consult it before deciding — the hook records the classification and logs the
  # disagreement, and the restart proceeds exactly as it did before.
  #
  # That restraint is the point. The classification has to be observed to be
  # right on real incidents before it is allowed to prevent a restart, because
  # the failure mode of getting it wrong is refusing to restart a genuinely dead
  # process. {Observatory::Analysis::Rules::WatchdogMisclassification} counts the
  # disagreements, which is how "observed to be right" becomes a number rather
  # than a feeling.
  #
  module Watchdog

    # What the watchdog should do, in ascending order of disruption.
    #
    RESTART            = "restart".freeze
    CAPTURE_AND_WAIT   = "capture_saturation_evidence".freeze
    RECYCLE_WORKER     = "recycle_worker".freeze
    INVESTIGATE        = "investigate_dependency".freeze
    NO_ACTION          = "no_action".freeze

    class << self

      # Classify the current state of this host's web processes.
      #
      # @param trigger [String] what prompted the check, e.g. "health_check_failed".
      # @param failed_probes [Integer] consecutive failed probes, when known.
      # @param service [String] the supervised service being judged.
      #
      # @return [Hash{Symbol => Object}] the classification, its evidence and its recommendation.
      #
      def classify(trigger: "health_check_failed", failed_probes: 0, service: "web")
        Safely.call("watchdog.classify", fallback: unknown_state(trigger, service)) do
          Instrumentation.suppress do
            capacity = ProcessSample.capacity_now
            long = long_running_requests

            build_classification(trigger:, failed_probes:, service:, capacity:, long:)
          end
        end
      end

      # Classify, record the event, and return the verdict.
      #
      # The entry point `bin/observatory-watchdog` calls. Recording happens
      # whatever the verdict, because the value of the record is the same either
      # way: a restart that was right is as worth knowing about as one that was
      # not.
      #
      # @param trigger [String] what prompted the check.
      # @param failed_probes [Integer] consecutive failed probes.
      # @param service [String] the supervised service.
      # @param action_taken [String, nil] what the supervisor is about to do.
      #
      # @return [Hash{Symbol => Object}] the classification.
      #
      def record!(trigger: "health_check_failed", failed_probes: 0, service: "web", action_taken: nil)
        verdict = classify(trigger:, failed_probes:, service:)

        Safely.call("watchdog.record") do
          Instrumentation.suppress do
            WatchdogEvent.create!(
              occurred_at:  Clock.wall,
              hostname:     Observatory.hostname,
              service:      service,
              trigger:      trigger,
              failed_probe_count: failed_probes,
              process_alive: verdict[:process_alive],
              busy_threads:  verdict[:busy_threads],
              max_threads:   verdict[:max_threads],
              backlog:       verdict[:backlog],
              long_running_requests: verdict[:long_running_requests],
              long_running_summary:  verdict[:long_running_summary],
              classification: verdict[:classification],
              action_taken:   action_taken,
              recommended_action: verdict[:recommended_action],
              advisory_reason: verdict[:reason]&.slice(0, 500),
              advisory_only:  true,
              release:        Release.current,
              evidence:       verdict[:evidence],
            )
          end
        end

        verdict
      end

      # The classification as JSON, for a shell script to read.
      #
      # @param options [Hash] any {record!} keyword.
      #
      # @return [String] one line of JSON.
      #
      def to_json_line(**options)
        JSON.generate(record!(**options))
      end

    private

      # Decide what is actually happening.
      #
      # The order of these checks is the classification: the most specific,
      # best-evidenced explanation wins, and "the process is dead" is only
      # reached when nothing else fits — the opposite of the current behaviour,
      # where it is the default.
      #
      # @param trigger [String] what prompted the check.
      # @param failed_probes [Integer] consecutive failed probes.
      # @param service [String] the supervised service.
      # @param capacity [Hash] the assembled cluster capacity.
      # @param long [Array<Observatory::RequestTrace>] long-running requests.
      #
      # @return [Hash{Symbol => Object}]
      #
      def build_classification(trigger:, failed_probes:, service:, capacity:, long:)
        alive = capacity[:workers_reporting].to_i.positive?
        busy = capacity[:busy_threads].to_i
        maximum = capacity[:max_threads].to_i
        saturated = maximum.positive? && busy >= maximum

        state =
          if !alive
            process_death(capacity)
          elsif saturated
            thread_saturation(capacity, long)
          elsif memory_pressure?(capacity)
            memory(capacity)
          elsif dependency_failure?
            dependency
          else
            inconclusive(capacity)
          end

        state.merge(
          trigger:, service:,
          failed_probes:,
          process_alive: alive,
          busy_threads: busy,
          max_threads: maximum,
          backlog: capacity[:backlog],
          workers_reporting: capacity[:workers_reporting],
          long_running_requests: long.size,
          long_running_summary: summarise(long),
          observed_at: Clock.wall,
        )
      end

      # Nothing is reporting. This is the case where a restart is right.
      #
      # @param capacity [Hash] the assembled cluster capacity.
      #
      # @return [Hash{Symbol => Object}]
      #
      def process_death(capacity)
        {
          classification: WatchdogEvent::PROCESS_DEATH,
          recommended_action: RESTART,
          confidence: "high",
          reason: "No worker has reported a sample recently. The process is not running, or is not able " \
                  "to run any Ruby at all.",
          evidence: {
            workers_reporting: 0,
            last_sample_at: capacity[:sampled_at],
          },
        }
      end

      # Alive, and full. This is the case a restart makes worse.
      #
      # @param capacity [Hash] the assembled cluster capacity.
      # @param long [Array<Observatory::RequestTrace>] long-running requests.
      #
      # @return [Hash{Symbol => Object}]
      #
      def thread_saturation(capacity, long)
        {
          classification: WatchdogEvent::THREAD_SATURATION,
          recommended_action: CAPTURE_AND_WAIT,
          confidence: capacity[:backlog].to_i.positive? ? "high" : "medium",
          reason: "The process is alive and every request thread is occupied. /up is an ordinary Rails " \
                  "request and cannot obtain a thread, so it fails exactly as it would if the process were " \
                  "dead. Restarting drops #{long.size} in-flight request(s) without changing the workload.",
          evidence: {
            workers_reporting: capacity[:workers_reporting],
            busy_threads:      capacity[:busy_threads],
            max_threads:       capacity[:max_threads],
            backlog:           capacity[:backlog],
            longest_request_seconds: long.first && (long.first.duration_ms / 1_000.0).round(1),
            capacity_sources:  capacity[:sources],
          },
        }
      end

      # @param capacity [Hash] the assembled cluster capacity.
      #
      # @return [Hash{Symbol => Object}]
      #
      def memory(capacity)
        {
          classification: WatchdogEvent::MEMORY_PRESSURE,
          recommended_action: RECYCLE_WORKER,
          confidence: "high",
          reason: "Worker memory is above the configured limit. Recycling one worker restores headroom " \
                  "without a full restart; the master keeps the listening socket.",
          evidence: { rss_bytes: capacity[:rss_bytes] },
        }
      end

      # @return [Hash{Symbol => Object}]
      #
      def dependency
        mysql = DependencySample.latest(DependencySample::MYSQL)
        redis = DependencySample.latest(DependencySample::REDIS)

        {
          classification: WatchdogEvent::DEPENDENCY_FAILURE,
          recommended_action: INVESTIGATE,
          confidence: "medium",
          reason: "The process is alive with threads available, but a dependency is not answering. " \
                  "Restarting the application will not fix a dependency.",
          evidence: {
            mysql_sampled_at: mysql&.sampled_at,
            redis_sampled_at: redis&.sampled_at,
          },
        }
      end

      # Alive, threads free, dependencies fine — and yet the probe failed.
      #
      # Deliberately does not recommend a restart. Something real is wrong and
      # this classifier cannot see it, which is worth saying rather than papering
      # over with the default action.
      #
      # @param capacity [Hash] the assembled cluster capacity.
      #
      # @return [Hash{Symbol => Object}]
      #
      def inconclusive(capacity)
        {
          classification: WatchdogEvent::UNKNOWN,
          recommended_action: NO_ACTION,
          confidence: "low",
          reason: "The process is alive with #{capacity[:idle_threads]} idle thread(s) and no dependency " \
                  "is failing, yet the probe did not succeed. Observatory cannot explain this from the " \
                  "measurements it has.",
          evidence: capacity.slice(:workers_reporting, :busy_threads, :max_threads, :idle_threads),
        }
      end

      # @return [Array<Observatory::RequestTrace>] requests over the extreme threshold, in flight or recent.
      #
      def long_running_requests
        live = Capacity.long_running(Observatory.config.extreme_request_threshold)
        return live.map { |execution| live_summary(execution) } if live.any?

        # In a saturated worker the sampler thread may not have been scheduled,
        # so fall back to what was recorded before the process stopped writing.
        #
        RequestTrace.since(2.minutes.ago)
                    .where(duration_ms: (Observatory.config.extreme_request_threshold * 1_000)..)
                    .order(duration_ms: :desc)
                    .limit(10)
                    .to_a
      end

      # @param execution [Observatory::Execution::Request] an in-flight request.
      #
      # @return [Struct] a duck-typed stand-in carrying the fields the caller reads.
      #
      def live_summary(execution)
        Struct.new(:endpoint, :duration_ms, :query_count, :trace_id, keyword_init: true).new(
          endpoint:    execution.endpoint,
          duration_ms: Clock.elapsed_ms(execution.started_monotonic),
          query_count: execution.query_count,
          trace_id:    execution.trace_id,
        )
      end

      # @param long [Array] the long-running requests.
      #
      # @return [Array<Hash>] a compact summary for the event row.
      #
      def summarise(long)
        long.first(10).map do |request|
          {
            endpoint:    request.endpoint,
            seconds:     (request.duration_ms.to_f / 1_000.0).round(1),
            query_count: request.query_count,
            trace_id:    request.trace_id,
          }
        end
      end

      # @param capacity [Hash] the assembled cluster capacity.
      #
      # @return [Boolean] whether worker memory is above the supervisor's limit.
      #
      def memory_pressure?(capacity)
        limit = ENV.fetch("WEB_MEM_LIMIT_MB", "2048").to_i * 1_024 * 1_024
        workers = capacity[:workers_reporting].to_i
        return false if workers.zero? || limit.zero?

        (capacity[:rss_bytes].to_i / workers) > limit
      end

      # @return [Boolean] whether a dependency has stopped being sampled.
      #
      def dependency_failure?
        [ DependencySample::MYSQL, DependencySample::REDIS ].any? do |dependency|
          sample = DependencySample.latest(dependency)

          sample.nil? || sample.sampled_at < 5.minutes.ago
        end
      end

      # @param trigger [String] what prompted the check.
      # @param service [String] the supervised service.
      #
      # @return [Hash{Symbol => Object}] the fallback when classification itself failed.
      #
      def unknown_state(trigger, service)
        {
          classification: WatchdogEvent::UNKNOWN,
          recommended_action: NO_ACTION,
          confidence: "low",
          reason: "Observatory could not classify this state.",
          trigger:, service:,
          process_alive: nil, busy_threads: nil, max_threads: nil, backlog: nil,
          long_running_requests: 0, long_running_summary: [], evidence: {},
        }
      end
    end
  end
end
