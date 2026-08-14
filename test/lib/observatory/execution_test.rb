# frozen_string_literal: true

require "test_helper"

module Observatory

  # The execution context is where the incident becomes legible: it is what turns
  # 86,359 individual notifications into "one query shape, 97% cached, 2.1
  # seconds of database time".
  #
  class ExecutionTest < ActiveSupport::TestCase

    setup do
      @execution = Execution::Request.new(
        trace_id: "abc", request_id: "req-1", http_method: "GET", path: "/steam/achievements/1",
      )
    end

    test "separates cached lookups from executed ones" do
      3.times { record(cached: false) }
      7.times { record(cached: true) }

      assert_equal 10, @execution.query_count
      assert_equal 7, @execution.cached_query_count
      assert_equal 3, @execution.executed_query_count
      assert_in_delta 0.7, @execution.cached_query_ratio, 0.001
    end

    test "groups repeated query shapes under one fingerprint" do
      1_000.times { |index| record(sql: "SELECT * FROM achievements WHERE id = #{index}") }

      assert_equal 1, @execution.query_groups.size

      group = @execution.dominant_query_group

      assert_equal 1_000, group.count
      assert_equal "SELECT * FROM achievements WHERE id = ?", group.fingerprint
      assert_equal "achievements", group.table
    end

    test "counts schema and transaction statements separately from application queries" do
      record(sql: "BEGIN")
      record(sql: "SHOW FULL FIELDS FROM `users`")
      record(sql: "SELECT * FROM users WHERE id = 1")
      record(sql: "COMMIT")

      assert_equal 4, @execution.query_count
      assert_equal 2, @execution.transaction_query_count
      assert_equal 1, @execution.schema_query_count
    end

    test "reproduces the incident signature end to end" do
      # The shape from the brief: a route performing tens of thousands of
      # lookups, the overwhelming majority served by the ActiveRecord query
      # cache, while the database itself does comparatively little work.
      41_722.times { |index| record(sql: "SELECT * FROM achievements WHERE id = #{index}", cached: true, ms: 0.01) }
      42_357.times { |index| record(sql: "SELECT * FROM trophies WHERE game_id = #{index}", cached: true, ms: 0.01) }
      2_280.times  { |index| record(sql: "SELECT * FROM games WHERE id = #{index}", cached: false, ms: 0.9) }

      @execution.complete!(status: 200)

      assert_equal 86_359, @execution.query_count
      assert_equal 84_079, @execution.cached_query_count
      assert_equal 2_280, @execution.executed_query_count
      assert_operator @execution.cached_query_ratio, :>, 0.97
      assert_not @execution.fingerprinting_truncated?,
                 "the default ceiling must sit above this incident so it is analysed at full fidelity"
      assert_equal 3, @execution.query_groups.size, "86,359 queries must reduce to 3 shapes"
      assert_equal 42_357, @execution.dominant_query_group.count
    end

    test "caps distinct query groups so a pathological execution has a memory ceiling" do
      with_observatory(max_query_groups: 10) do
        200.times { |index| record(sql: "SELECT * FROM table_#{index} WHERE name = 'x'") }
      end

      assert_operator @execution.query_groups.size, :<=, 11, "10 real groups plus the overflow bucket"
      assert_includes @execution.anomalies, :query_groups_truncated
      assert_equal 200, @execution.query_count, "every query is still counted"
    end

    test "stops fingerprinting past the ceiling but keeps counting" do
      with_observatory(max_fingerprinted_queries: 50) do
        100.times { |index| record(sql: "SELECT * FROM t WHERE id = #{index}") }

        assert @execution.fingerprinting_truncated?
      end

      assert_equal 100, @execution.query_count
      assert_includes @execution.query_groups.keys, Execution::Base::TRUNCATED_FINGERPRINT
    end

    test "never stores a raw bind value in a query group" do
      record(sql: "SELECT * FROM users WHERE email = 'someone@example.com' AND id = 42")

      group = @execution.dominant_query_group

      assert_no_match(/example\.com/, group.fingerprint)
      assert_no_match(/example\.com/, group.sample_sql)
      assert_no_match(/42/, group.sample_sql)
    end

    test "unaccounted time is what is left after every measured subsystem" do
      @execution.record_query(sql: "SELECT 1", name: nil, duration_ms: 100.0, cached: false)
      @execution.record_view(50.0)
      @execution.record_cache(:read, 10.0, hit: true)
      @execution.record_external_call(host: "api.steampowered.com", duration_ms: 40.0, status: 200)
      @execution.instance_variable_set(:@duration_ms, 1_000.0)

      assert_in_delta 800.0, @execution.unaccounted_ms, 0.001
    end

    test "aggregates external calls by host without listing them" do
      5.times { @execution.record_external_call(host: "api.steampowered.com", duration_ms: 20.0, status: 200) }
      @execution.record_external_call(host: "api.steampowered.com", duration_ms: 5.0, error: true)
      @execution.record_external_call(host: "psn.example", duration_ms: 100.0, status: 500)

      assert_equal 7, @execution.external_call_count
      assert_equal 2, @execution.external_calls.size
      assert_equal 6, @execution.external_calls["api.steampowered.com"][:count]
      assert_equal 1, @execution.external_calls["api.steampowered.com"][:errors]
    end

    test "thread-seconds makes a few slow requests outrank many fast ones" do
      slow = Execution::Request.new(trace_id: "s", request_id: nil, http_method: "GET", path: "/slow")
      slow.instance_variable_set(:@duration_ms, 20_000.0)

      fast = Execution::Request.new(trace_id: "f", request_id: nil, http_method: "GET", path: "/fast")
      fast.instance_variable_set(:@duration_ms, 20.0)

      assert_equal 200.0, slow.thread_seconds * 10, "10 slow requests cost 200 thread-seconds"
      assert_equal 20.0, fast.thread_seconds * 1_000, "1,000 fast requests cost 20 thread-seconds"
    end

    test "prefers the route template over the literal path for grouping" do
      @execution.resolve_route(controller: "Steam::AchievementsController", action: "show",
                               route: "/steam/achievements/:id")

      assert_equal "/steam/achievements/:id", @execution.endpoint
    end

    test "coarsens an unrouted path rather than storing its identifiers" do
      execution = Execution::Request.new(
        trace_id: "x", request_id: nil, http_method: "GET", path: "/nope/839292",
      )

      assert_equal "GET /nope/:id", execution.endpoint
    end

    test "records an exception without its backtrace" do
      @execution.record_exception(ArgumentError.new("something went wrong"))

      assert_equal "ArgumentError", @execution.exception_class
      assert_equal "something went wrong", @execution.exception_message
      assert_includes @execution.anomalies, :exception
      assert @execution.error?
    end

  private

    # @param sql [String] the statement to record.
    # @param cached [Boolean] whether the query cache served it.
    # @param ms [Float] its duration.
    #
    # @return [void]
    #
    def record(sql: "SELECT * FROM users WHERE id = 1", cached: false, ms: 0.5)
      @execution.record_query(sql:, name: "User Load", duration_ms: ms, cached:)
    end
  end
end
