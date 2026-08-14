# frozen_string_literal: true

require "test_helper"

module Observatory

  # The classification that separates a saturated process from a dead one.
  #
  # Getting this wrong in either direction is costly: calling saturation "death"
  # restarts a working process, and calling death "saturation" leaves a dead one
  # running. So both directions are tested, and the ambiguous case is required to
  # say it is ambiguous rather than guess.
  #
  class WatchdogTest < ActiveSupport::TestCase

    setup do
      clear_tables
      Capacity.reset!
    end

    teardown do
      clear_tables
      Capacity.reset!
    end

    test "classifies a full but reporting process as saturation, not death" do
      saturated_workers

      verdict = with_observatory { Watchdog.classify }

      assert_equal WatchdogEvent::THREAD_SATURATION, verdict[:classification]
      assert_equal Watchdog::CAPTURE_AND_WAIT, verdict[:recommended_action]
      assert verdict[:process_alive]
      assert_match(/alive/i, verdict[:reason])
    end

    test "classifies a process that has stopped reporting as death, and recommends a restart" do
      # No samples at all: nothing is running Ruby. This is the case where the
      # supervisor's existing behaviour is right, and the classifier has to agree.
      verdict = with_observatory { Watchdog.classify }

      assert_equal WatchdogEvent::PROCESS_DEATH, verdict[:classification]
      assert_equal Watchdog::RESTART, verdict[:recommended_action]
      assert_not verdict[:process_alive]
      assert_equal "high", verdict[:confidence]
    end

    test "says so plainly when it cannot explain the failure" do
      # Alive, threads free, dependencies fresh — and the probe still failed.
      # Guessing here would be worse than admitting the gap.
      healthy_workers
      fresh_dependencies

      verdict = with_observatory { Watchdog.classify }

      assert_equal WatchdogEvent::UNKNOWN, verdict[:classification]
      assert_equal Watchdog::NO_ACTION, verdict[:recommended_action]
      assert_equal "low", verdict[:confidence]
      assert_match(/cannot explain/i, verdict[:reason])
    end

    test "blames the dependency rather than the application when one stops responding" do
      healthy_workers
      # No dependency samples at all, so both look unreachable.

      verdict = with_observatory { Watchdog.classify }

      assert_equal WatchdogEvent::DEPENDENCY_FAILURE, verdict[:classification]
      assert_equal Watchdog::INVESTIGATE, verdict[:recommended_action]
      assert_match(/will not fix a dependency/i, verdict[:reason])
    end

    test "raises confidence when a real backlog was measured" do
      saturated_workers(backlog: 23)

      assert_equal "high", with_observatory { Watchdog.classify }[:confidence]
    end

    test "lowers confidence when the backlog could not be measured" do
      # backlog nil means unknown, not zero. Full occupancy alone is weaker
      # evidence than full occupancy plus a queue, and the verdict says so.
      saturated_workers(backlog: nil)

      assert_equal "medium", with_observatory { Watchdog.classify }[:confidence]
    end

    test "records the event with the state at the moment of the decision" do
      saturated_workers(backlog: 23)

      with_observatory(persist: true) do
        Watchdog.record!(trigger: "health_check_failed", failed_probes: 3, action_taken: "web_recycle")
      end

      event = WatchdogEvent.last

      assert_equal "health_check_failed", event.trigger
      assert_equal 3, event.failed_probe_count
      assert_equal "web_recycle", event.action_taken
      assert_equal Watchdog::CAPTURE_AND_WAIT, event.recommended_action
      assert event.advisory_only?, "phase 6 ships advisory only"
      assert event.disagreed?, "the recorded action and the recommendation differ, which is the finding"
      assert event.saturated_not_dead?
    end

    test "the recorded event is what the misclassification rule reads" do
      saturated_workers(backlog: 23)

      with_observatory(persist: true) do
        Watchdog.record!(trigger: "health_check_failed", failed_probes: 3, action_taken: "web_recycle")
      end

      assert_equal 1, WatchdogEvent.misclassified.count
    end

    test "classification never raises, whatever the database does" do
      ProcessSample.singleton_class.alias_method(:capacity_now_ok, :capacity_now)
      ProcessSample.define_singleton_method(:capacity_now) { |**| raise "database is gone" }

      verdict = with_observatory { Watchdog.classify }

      assert_equal WatchdogEvent::UNKNOWN, verdict[:classification]
      assert_equal Watchdog::NO_ACTION, verdict[:recommended_action]
    ensure
      ProcessSample.singleton_class.remove_method(:capacity_now)
      ProcessSample.singleton_class.alias_method(:capacity_now, :capacity_now_ok)
    end

    test "renders as one line of JSON for the shell to read" do
      saturated_workers

      line = with_observatory(persist: true) { Watchdog.to_json_line }
      parsed = JSON.parse(line)

      assert_equal 1, line.lines.size
      assert_equal WatchdogEvent::THREAD_SATURATION, parsed["classification"]
      assert_equal Watchdog::CAPTURE_AND_WAIT, parsed["recommended_action"]
    end

  private

    # @param backlog [Integer, nil] the measured backlog; nil means unmeasurable.
    #
    # @return [void]
    #
    def saturated_workers(backlog: 23)
      3.times do |worker|
        ProcessSample.create!(
          sampled_at: 10.seconds.ago, hostname: Observatory.hostname, process_id: 2_000 + worker,
          role: ProcessSample::WEB, capacity_source: "server",
          max_threads: 5, busy_threads: 5, idle_threads: 0, backlog:,
          saturated: true, saturated_for_seconds: 120.0, rss_bytes: 500_000_000,
        )
      end

      nil
    end

    # @return [void]
    #
    def healthy_workers
      3.times do |worker|
        ProcessSample.create!(
          sampled_at: 10.seconds.ago, hostname: Observatory.hostname, process_id: 3_000 + worker,
          role: ProcessSample::WEB, capacity_source: "server",
          max_threads: 5, busy_threads: 1, idle_threads: 4, backlog: 0,
          saturated: false, rss_bytes: 400_000_000,
        )
      end

      nil
    end

    # @return [void]
    #
    def fresh_dependencies
      [ DependencySample::MYSQL, DependencySample::REDIS ].each do |dependency|
        DependencySample.create!(sampled_at: 10.seconds.ago, dependency:, subject: "", metrics: {})
      end

      nil
    end

    # @return [void]
    #
    def clear_tables
      Instrumentation.suppress do
        [ WatchdogEvent, ProcessSample, DependencySample, RequestTrace ].each(&:delete_all)
      end

      nil
    end
  end
end
