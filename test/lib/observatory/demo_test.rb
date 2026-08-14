# frozen_string_literal: true

require "test_helper"

module Observatory

  # The demo is the executable definition of "working".
  #
  # If reproducing the incident stops producing a finding that names request
  # threads as the constrained resource, something has regressed — and this is
  # where that gets caught, rather than during the next real outage.
  #
  class DemoTest < ActiveSupport::TestCase

    setup do
      clear_tables
    end

    teardown do
      clear_tables
    end

    test "refuses to fabricate monitoring data unless explicitly enabled" do
      # Fabricated rows in an environment where somebody might act on them would
      # destroy the one property this system needs: that every row describes
      # something that really happened.
      with_observatory(demo_enabled: false) do
        error = assert_raises(RuntimeError) { Demo.reproduce_incident! }

        assert_match(/fabricated/i, error.message)
      end
    end

    test "reproducing the incident produces the documented signature" do
      with_observatory(demo_enabled: true, persist: true) do
        Demo.reproduce_incident!
      end

      worst = RequestTrace.where(endpoint: Demo::ENDPOINT).order(query_count: :desc).first

      assert_operator worst.duration_ms, :>, 10_000, "request duration > 10 seconds"
      assert_operator worst.query_count, :>, 50_000, "ActiveRecord lookups > 50,000"
      assert_operator worst.cached_query_ratio, :>, 0.90, "cached share > 90%"
      assert_operator worst.db_duration_ms / worst.duration_ms, :<, 0.25, "database execution relatively low"
      assert_operator worst.allocation_delta, :>, 1_000_000, "allocations high"
      assert_operator worst.estimated_gc_time_ms, :>, 1_000, "GC activity elevated"
      assert_equal 5, ProcessSample.web.last.busy_threads, "puma thread occupancy full"
    end

    test "the staged incident is diagnosed as an application problem, not a database one" do
      report = with_observatory(demo_enabled: true, persist: true) do
        Demo.reproduce_incident!
      end

      titles = report[:findings].join(" | ")

      assert_match(/Puma request capacity exhausted/, titles)
      assert_match(/Repeated ActiveRecord lookups/, titles)
      assert_match(/Health checks blocked/, titles)
      assert_match(/saturated but living/, titles)
    end

    test "the staged incident names request threads as the constrained resource" do
      with_observatory(demo_enabled: true, persist: true) { Demo.reproduce_incident! }

      incident = Incident.open_incidents.by_severity.first

      assert_equal "request threads", incident.constrained_resource
      assert_equal Demo::ENDPOINT, incident.primary_contributor
      assert_operator incident.contradicting_evidence.size, :>, 0,
                      "the healthy measurements must be on the record too"
    end

    test "every scenario runs without raising" do
      with_observatory(demo_enabled: true, persist: true) do
        Demo.scenarios.each_key do |name|
          Demo.run!(name)
        rescue StandardError => exception
          flunk("scenario #{name} raised #{exception.class}: #{exception.message}")
        end

        assert_operator RequestTrace.count, :>, 0
      end
    end

    test "an unknown scenario says what is available rather than failing obscurely" do
      with_observatory(demo_enabled: true) do
        error = assert_raises(ArgumentError) { Demo.run!(:no_such_thing) }

        assert_match(/Unknown scenario/, error.message)
        assert_match(/slow_sql/, error.message)
      end
    end

    test "clearing removes only the demo's own rows" do
      real = nil

      with_observatory(demo_enabled: true, persist: true) do
        real = RequestTrace.create!(
          trace_id: Trace.generate, started_at: Time.current, endpoint: "/real",
          duration_ms: 12.0, release: "abc123",
        )
        Demo.reproduce_incident!

        assert_operator RequestTrace.count, :>, 1

        Demo.clear!
      end

      assert_equal [ real.id ], RequestTrace.pluck(:id), "real data must survive the clear"
    end

  private

    # @return [void]
    #
    def clear_tables
      Instrumentation.suppress do
        [ IncidentEvidence, Incident, QueryGroup, RequestTrace, JobTrace, RouteRollup,
          JobRollup, ProcessSample, DependencySample, WatchdogEvent, ].each(&:delete_all)
      end

      nil
    end
  end
end
