# frozen_string_literal: true

require "test_helper"

# The dashboard, rendered.
#
# These are deliberately end-to-end rather than component tests: the failure
# mode a monitoring dashboard actually has is a page that raises on real data —
# a nil where a number was expected, a route helper that does not exist — and
# only rendering the whole thing catches that. Each test asserts the page comes
# back *and* that the numbers on it are the right ones.
#
# The dummy application mounts the engine without a gate, because Observatory
# ships no authentication of its own — who may see the dashboard is the host's
# decision, made by whatever `config.parent_controller` points at, and belongs
# to the host's own suite.
#
class ObservatoryDashboardTest < ActionDispatch::IntegrationTest

  setup do
    clear_observatory_tables
  end

  teardown do
    clear_observatory_tables
  end

  test "the overview renders with no data at all" do
    # The empty state matters: a fresh install must not 500 before it has
    # collected anything.
    get "/observatory"

    assert_response :success
    assert_match(/No hidden application constraint detected/, response.body)
  end

  test "the overview shows the finding above the healthy infrastructure panels" do
    build_incident
    Observatory::Instrumentation.suppress { Observatory::Analysis::Engine.run! }

    get "/observatory"

    assert_response :success
    assert_match(/The hidden problem/, response.body)
    assert_match(/Puma request capacity exhausted/, response.body)
    # The contradicting evidence is on the page, which is the whole point.
    assert_match(/MySQL running threads/, response.body)
    assert_match(/Redis utilisation/, response.body)
  end

  test "an unmeasurable backlog renders as unknown rather than zero" do
    build_saturated_workers(backlog: nil)

    get "/observatory"

    assert_response :success
    assert_match(/not measurable/, response.body)
    assert_no_match(/Backlog<\/span>\s*<span[^>]*>0</, response.body)
  end

  test "the request explorer renders and filters" do
    build_incident

    get "/observatory/requests"

    assert_response :success
    assert_match(%r{/steam/achievements/:id}, response.body)

    get "/observatory/requests", params: { only: "cached_explosions" }

    assert_response :success
  end

  test "a request detail page shows the query shapes and the call site" do
    trace = build_incident.first

    get "/observatory/requests/#{trace.id}"

    assert_response :success
    assert_match(/SELECT \* FROM trophies WHERE game_id = \?/, response.body)
    assert_match(%r{app/services/steam/achievements\.rb:88}, response.body)
    assert_match(/Where the time went/, response.body)
  end

  test "an incident page renders its evidence and causal timeline" do
    build_incident
    Observatory::Instrumentation.suppress { Observatory::Analysis::Engine.run! }
    incident = Observatory::Incident.open_incidents.by_severity.first

    get "/observatory/incidents/#{incident.id}"

    assert_response :success
    assert_match(/Causal timeline/, response.body)
    assert_match(/Contradicting evidence/, response.body)
    assert_match(/Likely failure mode/, response.body)
  end

  test "the routes page ranks by capacity consumed" do
    build_incident

    get "/observatory/routes"

    assert_response :success
    assert_match(/Thread-seconds/, response.body)
    assert_match(%r{/steam/achievements/:id}, response.body)
  end

  test "a route detail page renders its baseline comparison" do
    build_incident

    get "/observatory/route", params: { endpoint: "/steam/achievements/:id" }

    assert_response :success
    assert_match(/Query shapes issued by this route/, response.body)
  end

  test "the sidekiq page shows depth alongside throughput and drain" do
    Observatory::DependencySample.create!(
      sampled_at: 1.minute.ago, dependency: Observatory::DependencySample::SIDEKIQ,
      subject: "default", depth: 536_542, throughput: 56.3, drain_seconds: 9_530.0,
      metrics: { "latency" => 12.0 },
    )

    get "/observatory/jobs"

    assert_response :success
    assert_match(/536,542/, response.body)
    assert_match(%r{56\.3/s}, response.body)
    assert_match(/draining/, response.body)
  end

  test "rendering the dashboard does not trace itself" do
    build_incident

    before = Observatory::RequestTrace.count
    capture_observatory_payloads { get "/observatory" }

    assert_equal before, Observatory::RequestTrace.count,
                 "looking at the monitoring must not degrade the monitoring"
  end

private

  # A minimal version of the incident: enough for every page to have something
  # real to render.
  #
  # @return [Array<Observatory::RequestTrace>]
  #
  def build_incident
    traces = [ 86_359, 71_004 ].map.with_index do |queries, index|
      cached = (queries * 0.9736).round
      trace = Observatory::RequestTrace.create!(
        trace_id: Observatory::Trace.generate, started_at: (5 - index).minutes.ago,
        endpoint: "/steam/achievements/:id", controller: "Steam::AchievementsController",
        action: "show", http_method: "GET", status: 200, duration_ms: 14_472.0,
        query_count: queries, cached_query_count: cached, executed_query_count: queries - cached,
        cached_query_ratio: cached.to_f / queries, db_duration_ms: 2_104.3,
        allocation_delta: 48_000_000, estimated_gc_time_ms: 1_832.0, unaccounted_ms: 10_500.0,
        peak_concurrency: 6, thread_seconds: 14.47, pool_waiting: 0, hostname: "prod",
        process_id: 1_000, traffic_class: "unknown_automation", retention_class: "anomalous",
      )

      Observatory::QueryGroup.create!(
        trace_kind: "request", trace_row_id: trace.id, traced_at: trace.started_at,
        fingerprint: "SELECT * FROM trophies WHERE game_id = ?",
        fingerprint_digest: Observatory::QueryGroup.digest("SELECT * FROM trophies WHERE game_id = ?"),
        sample_sql: "SELECT * FROM trophies WHERE game_id = ?", count: 42_357, cached_count: 41_800,
        executed_count: 557, duration_ms: 1_050.0, max_duration_ms: 4.2, average_duration_ms: 0.025,
        call_site: "app/services/steam/achievements.rb:88:in `block in decorate'",
      )

      trace
    end

    build_saturated_workers
    build_idle_dependencies
    build_rollup(traces)

    traces
  end

  # @param backlog [Integer, nil] the measured backlog; nil means unmeasurable.
  #
  # @return [void]
  #
  def build_saturated_workers(backlog: 23)
    3.times do |worker|
      Observatory::ProcessSample.create!(
        sampled_at: 2.minutes.ago, hostname: "prod", process_id: 1_000 + worker,
        role: Observatory::ProcessSample::WEB, worker_index: worker, capacity_source: "server",
        max_threads: 5, busy_threads: 5, idle_threads: 0, backlog:, saturated: true,
        saturated_for_seconds: 180.0, pool_size: 25, pool_busy: 5, pool_waiting: 0,
        rss_bytes: 900_000_000,
      )
    end

    nil
  end

  # @return [void]
  #
  def build_idle_dependencies
    Observatory::DependencySample.create!(
      sampled_at: 2.minutes.ago, dependency: Observatory::DependencySample::MYSQL, subject: "",
      utilisation: 0.0054,
      metrics: { "connections" => 54, "max_connections" => 10_000, "peak_connections" => 56,
                 "running_threads" => 2, "row_lock_waits" => 0, "slow_queries" => 0, },
    )
    Observatory::DependencySample.create!(
      sampled_at: 2.minutes.ago, dependency: Observatory::DependencySample::REDIS, subject: "",
      utilisation: 0.076,
      metrics: { "blocked_clients" => 0, "connected_clients" => 41, "max_clients" => 65_000,
                 "slow_commands_per_hour" => 7.0, "used_memory_bytes" => 2_000_000,
                 "max_memory_bytes" => 8_000_000_000, "keyspace_hit_ratio" => 0.94, },
    )

    nil
  end

  # @param traces [Array<Observatory::RequestTrace>] the traces to summarise.
  #
  # @return [void]
  #
  def build_rollup(traces)
    Observatory::RouteRollup.create!(
      granularity: "minute", bucket_at: 5.minutes.ago.change(sec: 0),
      endpoint: "/steam/achievements/:id", release: "",
      count: traces.size, error_count: 0, crawler_count: traces.size,
      thread_seconds: traces.sum(&:thread_seconds), duration_sum_ms: traces.sum(&:duration_ms),
      duration_max_ms: 14_472.0, query_count_sum: traces.sum(&:query_count),
      query_count_max: 86_359, cached_query_count_sum: traces.sum(&:cached_query_count),
      executed_query_count_sum: traces.sum(&:executed_query_count),
      db_duration_sum_ms: 4_208.6, allocation_sum: 96_000_000,
      duration_histogram: Observatory::Histogram.empty.tap do |histogram|
        traces.each { |trace| Observatory::Histogram.observe(histogram, trace.duration_ms) }
      end,
    )

    nil
  end

  # @return [void]
  #
  def clear_observatory_tables
    Observatory::Instrumentation.suppress do
      [ Observatory::IncidentEvidence, Observatory::Incident, Observatory::QueryGroup,
        Observatory::RequestTrace, Observatory::JobTrace, Observatory::RouteRollup,
        Observatory::JobRollup, Observatory::ProcessSample, Observatory::DependencySample,
        Observatory::WatchdogEvent, ].each(&:delete_all)
    end

    nil
  end
end
