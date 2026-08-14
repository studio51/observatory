# frozen_string_literal: true

require "test_helper"

module Observatory

  # Persistence, rollups and retention: the path from a finished execution to a
  # row, and from a row to its eventual deletion.
  #
  class PersistenceTest < ActiveSupport::TestCase

    setup do
      Pipeline.reset!
      Pipeline::Aggregator.reset!
      Sampling::Decision.reset!
      clear_observatory_tables
    end

    teardown do
      Pipeline::Aggregator.reset!
      Sampling::Decision.reset!
      clear_observatory_tables
    end

    test "a retained request becomes one trace row and one row per query shape" do
      with_observatory(persist: true, synchronous: true) do
        Pipeline.submit(incident_shaped_request)
      end

      trace = RequestTrace.last

      assert_not_nil trace
      assert_equal "/steam/achievements/:id", trace.endpoint
      assert_equal 86_359, trace.query_count
      assert_equal 84_079, trace.cached_query_count
      assert_equal 2_280, trace.executed_query_count
      assert_in_delta 0.9736, trace.cached_query_ratio, 0.0005

      assert_equal 3, trace.query_groups.count, "86,359 queries became 3 rows, not 86,359"
      assert_equal 42_357, trace.dominant_query_group.count
    end

    test "a stored query group carries no bind values" do
      with_observatory(persist: true, synchronous: true) do
        execution = build_request
        execution.record_query(
          sql: "SELECT * FROM users WHERE email = 'someone@example.com' AND id = 42",
          name: "User Load", duration_ms: 0.5, cached: false,
        )
        execution.complete!(status: 200)
        Pipeline.submit(execution)
      end

      group = QueryGroup.last

      assert_no_match(/example\.com/, group.fingerprint)
      assert_no_match(/example\.com/, group.sample_sql.to_s)
      assert_equal "users", group.table_name
    end

    test "a dropped request still updates the rollup" do
      # The invariant that makes rate questions answerable: rollups see every
      # execution, traces only the sampled ones.
      with_observatory(persist: true, synchronous: true,
                       normal_request_sample_rate: 0.0, route_reservoir_interval: 0) do
        5.times { Pipeline.submit(build_request(duration_ms: 40.0, status: 200)) }
        Pipeline::Aggregator.flush!(now: 2.minutes.from_now)
      end

      assert_equal 0, RequestTrace.count, "no trace was worth keeping"

      rollup = RouteRollup.last

      assert_equal 5, rollup.count, "but all five requests were counted"
      assert_equal 0, rollup.sampled_trace_count
    end

    test "rollup percentiles come from every request, not from the sample" do
      with_observatory(persist: true, synchronous: true,
                       normal_request_sample_rate: 0.0, route_reservoir_interval: 0) do
        90.times { Pipeline.submit(build_request(duration_ms: 20.0)) }
        10.times { Pipeline.submit(build_request(duration_ms: 4_000.0)) }
        Pipeline::Aggregator.flush!(now: 2.minutes.from_now)
      end

      rollup = RouteRollup.last

      assert_equal 100, rollup.count
      assert_operator rollup.p50, :<=, 25.0, "the median is one of the fast requests"
      assert_operator rollup.p95, :>=, 2_500.0, "and p95 sees the slow tail"
    end

    test "rollups from separate processes add rather than overwrite" do
      # Three puma workers and two sidekiq processes each flush their own view of
      # the same minute. Whoever writes last must not discard the others.
      with_observatory(persist: true, synchronous: true) do
        2.times { Pipeline.submit(build_request(duration_ms: 10.0)) }
        Pipeline::Aggregator.flush!(now: 2.minutes.from_now)

        3.times { Pipeline.submit(build_request(duration_ms: 10.0)) }
        Pipeline::Aggregator.flush!(now: 2.minutes.from_now)
      end

      assert_equal 1, RouteRollup.count, "one bucket, not two"
      assert_equal 5, RouteRollup.last.count, "carrying all five requests"
    end

    test "the aggregator leaves the current minute alone" do
      with_observatory(persist: true, synchronous: true) do
        Pipeline.submit(build_request)

        assert_equal 0, Pipeline::Aggregator.flush!(now: Time.current),
                     "an in-progress minute must not be written half-finished"
        assert_equal 1, Pipeline::Aggregator.flush!(now: 2.minutes.from_now)
      end
    end

    test "the buffer feeds the writer, and the writer persists in batches" do
      with_observatory(persist: true, synchronous: false) do
        3.times { Pipeline.submit(incident_shaped_request) }

        assert_equal 3, Pipeline.buffer.size, "nothing reached the database on the request path"

        written = Pipeline::Writer.drain!(timeout: 5)

        assert_equal 3, written
        assert_equal 3, RequestTrace.count
      end
    end

    test "a persistence failure cannot break the execution that produced it" do
      with_observatory(persist: true, synchronous: true) do
        RequestTrace.singleton_class.alias_method(:insert_all_without_failure, :insert_all)
        RequestTrace.define_singleton_method(:insert_all) { |*, **| raise ActiveRecord::StatementInvalid, "gone" }

        assert_nothing_raised { Pipeline.submit(build_request) }
        assert_operator Safely.failure_counts["pipeline.writer.write"], :>=, 1
      ensure
        RequestTrace.singleton_class.remove_method(:insert_all)
        RequestTrace.singleton_class.alias_method(:insert_all, :insert_all_without_failure)
      end
    end

    test "retention deletes ordinary traces sooner than error traces" do
      with_observatory(persist: true, synchronous: true) do
        create_trace(retention_class: "raw", started_at: 2.days.ago)
        create_trace(retention_class: "anomalous", started_at: 2.days.ago)
        create_trace(retention_class: "error", started_at: 2.days.ago)
        create_trace(retention_class: "raw", started_at: 1.hour.ago)

        Retention.sweep!
      end

      assert_equal 1, RequestTrace.where(retention_class: "raw").count, "the day-old ordinary trace is gone"
      assert_equal 1, RequestTrace.where(retention_class: "anomalous").count
      assert_equal 1, RequestTrace.where(retention_class: "error").count
    end

    test "retention deletes query groups without joining back to their trace" do
      with_observatory(persist: true, synchronous: true) do
        QueryGroup.create!(
          trace_kind: "request", trace_row_id: 1, traced_at: 60.days.ago,
          fingerprint: "SELECT ?", fingerprint_digest: QueryGroup.digest("SELECT ?"), count: 1,
        )
        QueryGroup.create!(
          trace_kind: "request", trace_row_id: 2, traced_at: 1.hour.ago,
          fingerprint: "SELECT ?", fingerprint_digest: QueryGroup.digest("SELECT ?"), count: 1,
        )

        Retention.sweep!
      end

      assert_equal 1, QueryGroup.count
    end

    test "retention never sweeps an open incident" do
      with_observatory(persist: true, synchronous: true, incident_retention: 1.day) do
        open_incident = create_incident(status: Incident::OPEN, ended_at: nil, started_at: 30.days.ago)
        resolved = create_incident(status: Incident::RESOLVED, ended_at: 30.days.ago, started_at: 30.days.ago)

        Retention.sweep!

        assert Incident.exists?(open_incident.id), "an unexamined incident is not one that stopped mattering"
        assert_not Incident.exists?(resolved.id)
      end
    end

    test "a deployment is recorded once however many processes boot on it" do
      with_observatory(persist: true, synchronous: true) do
        3.times { Deployment.record!(Release.details) }
      end

      assert_equal 1, Deployment.where(release: Release.current).count
    end

  private

    # @return [void]
    #
    def clear_observatory_tables
      Instrumentation.suppress do
        [ QueryGroup, RequestTrace, JobTrace, RouteRollup, JobRollup,
          IncidentEvidence, Incident, Deployment, ProcessSample, DependencySample, ].each(&:delete_all)
      end

      nil
    end

    # A finished request carrying the incident's signature.
    #
    # @return [Observatory::Execution::Request]
    #
    def incident_shaped_request
      execution = build_request(duration_ms: 14_472.0)

      41_722.times { |i| record(execution, "SELECT * FROM achievements WHERE id = #{i}", cached: true) }
      42_357.times { |i| record(execution, "SELECT * FROM trophies WHERE game_id = #{i}", cached: true) }
      2_280.times  { |i| record(execution, "SELECT * FROM games WHERE id = #{i}", cached: false) }

      execution
    end

    # @param execution [Observatory::Execution::Base] the context to collect into.
    # @param sql [String] the statement.
    # @param cached [Boolean] whether the query cache served it.
    #
    # @return [void]
    #
    def record(execution, sql, cached:)
      execution.record_query(sql:, name: "Load", duration_ms: 0.01, cached:)
    end

    # @param duration_ms [Float] the request's duration.
    # @param status [Integer] its response status.
    #
    # @return [Observatory::Execution::Request] a finished request.
    #
    def build_request(duration_ms: 120.0, status: 200)
      execution = Execution::Request.new(
        trace_id: Trace.generate, request_id: "r", http_method: "GET", path: "/steam/achievements/1",
      )
      execution.resolve_route(controller: "Steam::AchievementsController", action: "show",
                              route: "/steam/achievements/:id")
      execution.classify(client_id: nil, traffic_class: :human, user_agent: "Mozilla/5.0")
      execution.instance_variable_set(:@duration_ms, duration_ms)
      execution.complete!(status:)

      execution
    end

    # @param attributes [Hash] overrides for the trace row.
    #
    # @return [Observatory::RequestTrace]
    #
    def create_trace(**attributes)
      RequestTrace.create!(
        { trace_id: Trace.generate, started_at: Time.current, endpoint: "/x", duration_ms: 1.0 }.merge(attributes),
      )
    end

    # @param attributes [Hash] overrides for the incident row.
    #
    # @return [Observatory::Incident]
    #
    def create_incident(**attributes)
      Incident.create!(
        {
          fingerprint: SecureRandom.hex(8), rule: "test", title: "Test incident",
          severity: Incident::WARNING, started_at: Time.current, last_seen_at: Time.current,
          confidence: Incident::MEDIUM,
        }.merge(attributes),
      )
    end
  end
end
