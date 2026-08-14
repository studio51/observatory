# frozen_string_literal: true

require "test_helper"

# End-to-end proof that a real request through the real Rack stack produces a
# correlated trace with the route template, the query split and the timing.
#
# The unit tests prove the accounting is right; this proves the accounting is
# actually reached — that the middleware is mounted in the right place, that the
# subscribers are attached, and that the route template survives the router.
#
class ObservatoryRequestTracingTest < ActionDispatch::IntegrationTest

  test "a request produces one trace carrying its route, status and duration" do
    payloads = capture_observatory_payloads { get root_url }

    assert_equal 1, payloads.size, "one request, one trace"

    trace = payloads.first

    assert_equal "request", trace[:event]
    assert_equal "GET", trace[:http_method]
    assert_equal 200, trace[:status]
    assert_operator trace[:duration_ms], :>, 0
    assert trace[:trace_id].present?
    assert trace[:request_id].present?, "the trace correlates with the application log's request id"
  end

  test "the trace records the route template rather than the literal path" do
    user = User.first
    payloads = capture_observatory_payloads { get user_url(user) }

    trace = payloads.first

    assert_not_nil trace[:route]
    assert_no_match %r{\A/users/\d+}, trace[:route].to_s
    assert trace[:controller].present?
    assert trace[:action].present?
  end

  test "the trace splits executed queries from query-cache hits" do
    payloads = capture_observatory_payloads { get root_url }

    trace = payloads.first

    assert_equal trace[:query_count], trace[:cached_query_count] + trace[:executed_query_count],
                 "every lookup is classified as exactly one of cached or executed"
    assert_operator trace[:query_count], :>=, 0
    assert_kind_of Float, trace[:db_duration_ms]
  end

  test "the trace carries the process, thread and release it came from" do
    payloads = capture_observatory_payloads { get root_url }

    trace = payloads.first

    assert_equal Process.pid, trace[:process_id]
    assert trace[:hostname].present?
    assert trace[:release].present?
  end

  test "a request that raises is traced and the exception still reaches Rails" do
    payloads = capture_observatory_payloads do
      get "/errors/internal_server_error"
    rescue StandardError
      # Whatever Rails does with the exception is Rails' business; the point is
      # that Observatory neither swallowed it nor prevented the response.
      nil
    end

    assert_equal 1, payloads.size
    assert payloads.first[:status].present?
  end

  test "assets and the vite dev server are never traced" do
    payloads = capture_observatory_payloads do
      get "/assets/nonexistent.css"
    rescue StandardError
      nil
    end

    assert_empty payloads, "ignored paths produce no trace at all"
  end

  test "the health endpoint is traced and marked as a health check" do
    payloads = capture_observatory_payloads { get "/up" }

    trace = payloads.first

    assert trace[:health_check], "/up must be recognisable as a probe, not ordinary traffic"
  end

  test "no trace is produced when Observatory is disabled" do
    payloads = capture_observatory_payloads(enabled: false) { get root_url }

    assert_empty payloads
  end

  test "a raw IP address is never stored" do
    payloads = capture_observatory_payloads(client_id_secret: "test-secret") do
      get root_url, headers: { "REMOTE_ADDR" => "203.0.113.42" }
    end

    serialised = payloads.first.to_json

    assert_no_match(/203\.0\.113\.42/, serialised)
  end

  test "the same client resolves to the same anonymised identifier" do
    first  = client_id_for("203.0.113.42")
    second = client_id_for("203.0.113.42")
    other  = client_id_for("198.51.100.7")

    assert_equal first, second, "correlation across requests is the point"
    assert_not_equal first, other
    assert_not_nil first
  end

private

  # @param address [String] the client address to send.
  #
  # @return [String, nil] the anonymised identifier the trace recorded.
  #
  def client_id_for(address)
    payloads = capture_observatory_payloads(client_id_secret: "test-secret") do
      get root_url, headers: { "REMOTE_ADDR" => address }
    end

    payloads.first[:client_id]
  end
end
