# frozen_string_literal: true

require "test_helper"

module Observatory
  module Performance

    # The overhead budget, enforced.
    #
    # A monitoring system's cost is a promise, and a promise nobody measures is a
    # guess. These tests measure the real thing and fail the build if it drifts.
    #
    # Measured on the development machine (Ruby 4.0.5, YJIT on, no coverage):
    #
    # | Path                                    | Measured   | Budget    |
    # | --------------------------------------- | ---------- | --------- |
    # | Ordinary request (30 queries)           | 0.11 ms    | < 1 ms    |
    # | Per-query collection                    | 3.8 us     | < 8 us    |
    # | The 86,359-query incident               | 325 ms     | < 5% of it|
    # | Request context open + close            | 0.012 ms   | < 1 ms    |
    # | Call-site capture (rationed to 3/exec)  | 5 us       | —         |
    #
    # ## Why these skip under coverage
    #
    # `SimpleCov`'s line coverage instruments every line of Ruby and costs 2-3x on
    # tight loops — under it, per-query collection measures 7.8 microseconds
    # rather than 3.8. Asserting a budget against an instrumented number would be
    # measuring SimpleCov, not Observatory, so these tests decline to run rather
    # than report a figure that is not true. Run them for real with:
    #
    #   COVERAGE=0 bin/rails test test/lib/observatory/performance
    #
    # ## On tolerances
    #
    # The budgets sit well above the observed cost rather than tightly around it.
    # They exist to catch a regression of the "someone put `caller_locations` in
    # the SQL subscriber" kind — an order of magnitude, not a percentage — without
    # failing the build because CI was busy. Each test prints its measurement, so
    # the real number is visible even when the assertion passes.
    #
    class OverheadTest < ActiveSupport::TestCase
      QUERIES     = 20_000    # iterations for the per-query measurements
      NORMAL_QUERIES = 30     # queries in a representative ordinary request

      setup do
        skip(<<~REASON.squish) if coverage_running?
          Timing is meaningless under line-coverage instrumentation.
          Run: COVERAGE=0 bin/rails test test/lib/observatory/performance
        REASON

        warm_up
      end

      test "an ordinary request's collection overhead stays inside the one-millisecond budget" do
        elapsed = measure do
          1_000.times do
            execution = build_execution
            NORMAL_QUERIES.times do |index|
              execution.record_query(
                sql: "SELECT * FROM users WHERE id = #{index}", name: "User Load",
                duration_ms: 0.2, cached: false,
              )
            end
          end
        end

        per_request = elapsed / 1_000
        report("ordinary request (#{NORMAL_QUERIES} queries)", per_request, "ms")

        assert_operator per_request, :<, 1.0, "the median request must stay inside the 1 ms budget"
      end

      test "collecting a query costs single-digit microseconds" do
        execution = build_execution
        sql = "SELECT `achievements`.* FROM `achievements` WHERE `achievements`.`id` = 12345 LIMIT 1"

        elapsed = measure do
          QUERIES.times { execution.record_query(sql:, name: "Achievement Load", duration_ms: 0.1, cached: true) }
        end

        per_query_us = (elapsed / QUERIES) * 1_000
        report("per-query collection", per_query_us, "us")

        assert_equal QUERIES, execution.query_count
        assert_operator per_query_us, :<, 8.0, "per-query collection must stay under 8 microseconds"
      end

      test "measuring the incident costs a small fraction of the incident" do
        # 86,359 queries on a 14.4-second request. The instrumentation is only
        # defensible if watching that costs a fraction of a percent of it.
        execution = build_execution

        elapsed = measure do
          41_722.times { |i| collect(execution, "SELECT * FROM achievements WHERE id = #{i}", cached: true) }
          42_357.times { |i| collect(execution, "SELECT * FROM trophies WHERE game_id = #{i}", cached: true) }
          2_280.times  { |i| collect(execution, "SELECT * FROM games WHERE id = #{i}", cached: false) }
        end

        share = (elapsed / 1_000 / 14.4) * 100
        report("86,359-query incident", elapsed, "ms (#{share.round(2)}% of the 14.4s request)")

        assert_equal 86_359, execution.query_count
        assert_equal 3, execution.query_groups.size
        assert_operator share, :<, 5.0, "collecting the incident must cost under 5% of the request it describes"
      end

      test "a disabled subscriber adds almost nothing to a query" do
        payload = { sql: "SELECT 1", name: "Load", cached: false, row_count: 1 }

        # Both halves publish the same notification with the same other
        # subscribers attached (Rails' own log subscriber included) — the only
        # difference is whether Observatory is listening. Comparing against an
        # unsubscribed notification name instead would measure ActiveSupport's
        # "nobody is listening" fast path, not Observatory.
        Collectors::ActiveRecord.detach!
        without = measure do
          QUERIES.times { ActiveSupport::Notifications.instrument("sql.active_record", payload) { nil } }
        end

        Collectors::ActiveRecord.install!
        with = measure do
          QUERIES.times { ActiveSupport::Notifications.instrument("sql.active_record", payload) { nil } }
        end

        # No execution is in progress, so this is exactly what every query in the
        # application pays while Observatory is switched off.
        overhead_ns = ((with - without) / QUERIES) * 1_000_000
        report("disabled per-query overhead", overhead_ns, "ns")

        assert_operator overhead_ns, :<, 2_000.0, "a disabled subscriber must stay under 2 microseconds"
      ensure
        Collectors::ActiveRecord.install!
      end

      test "opening and closing a request context costs well under a millisecond" do
        iterations = 2_000

        elapsed = measure do
          iterations.times do
            context = Execution::Request.new(
              trace_id: Trace.generate, request_id: "r", http_method: "GET", path: "/x",
            )
            Capacity.enter(context)
            context.complete!(status: 200)
            Capacity.leave(context)
          end
        end

        per_request = elapsed / iterations
        report("request context lifecycle", per_request, "ms")

        assert_operator per_request, :<, 1.0
      ensure
        Capacity.reset!
      end

      test "call-site capture is expensive, which is why it is rationed to three per execution" do
        iterations = 2_000

        elapsed = measure { iterations.times { CallSite.find(Observatory.config) } }

        per_capture = (elapsed / iterations) * 1_000
        report("call-site capture", per_capture, "us")

        # The design consequence, asserted: three captures are free, but running
        # this per query on the 86,359-query request would add hundreds of
        # milliseconds. If this assertion ever fails because capture became free,
        # the rationing can be revisited — until then it stands.
        unrationed = (per_capture * 86_359) / 1_000
        report("...if it ran per query", unrationed, "ms")

        assert_operator unrationed, :>, 50.0,
                        "capture is still costly enough that rationing it is the right call"
      end

      test "an execution's memory stays bounded however pathological it gets" do
        execution = build_execution

        200_000.times do |index|
          collect(execution, "SELECT * FROM table_#{index % 5_000} WHERE id = #{index}", cached: true)
        end

        # The configured cap, plus at most the two marker buckets (overflow and
        # fingerprinting truncation).
        assert_operator execution.query_groups.size, :<=, Observatory.config.max_query_groups + 2,
                        "distinct shapes are capped, so memory cannot grow with pathology"
        assert_equal 200_000, execution.query_count, "but every query is still counted"
        assert execution.fingerprinting_truncated?, "and the trace says its group counts are a lower bound"
      end

    private

      # @return [Boolean] whether line-coverage instrumentation is distorting timings.
      #
      def coverage_running?
        defined?(SimpleCov) && SimpleCov.running
      end

      # Give YJIT something to compile before anything is measured. Without this
      # the first benchmark to run absorbs the warm-up cost of every other.
      #
      # @return [void]
      #
      def warm_up
        execution = build_execution
        5_000.times { |index| collect(execution, "SELECT * FROM warmup WHERE id = #{index}", cached: true) }
        200.times { Sql::Fingerprint.call("SELECT * FROM warmup WHERE id = 1") }

        nil
      end

      # @param execution [Observatory::Execution::Base] the context to collect into.
      # @param sql [String] the statement to record.
      # @param cached [Boolean] whether the query cache served it.
      #
      # @return [void]
      #
      def collect(execution, sql, cached:)
        execution.record_query(sql:, name: "Load", duration_ms: 0.01, cached:)
      end

      # @return [Observatory::Execution::Request] a fresh context to collect into.
      #
      def build_execution
        Execution::Request.new(trace_id: "bench", request_id: nil, http_method: "GET", path: "/bench")
      end

      # @yield the work to time.
      #
      # @return [Float] milliseconds elapsed.
      #
      def measure
        GC.start
        started = Clock.monotonic
        yield

        Clock.elapsed_ms(started)
      end

      # Print a measurement so the real number is visible in the test output even
      # when the assertion passes.
      #
      # @param label [String] what was measured.
      # @param value [Float] the measurement.
      # @param unit [String] its unit.
      #
      # @return [void]
      #
      def report(label, value, unit)
        puts format("\n  [observatory] %-38s %9.3f %s", label, value, unit)

        nil
      end
    end
  end
end
