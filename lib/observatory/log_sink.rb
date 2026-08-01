# frozen_string_literal: true

require "json"

module Observatory

  # Writes each retained execution to `log/observatory.log` as one JSON line.
  #
  # This is Phase 1's whole deliverable, and it is deliberately useful before any
  # database table or dashboard exists. With nothing else installed, this answers
  # the question the incident starts with:
  #
  #   $ jq 'select(.query_count > 10000)' log/observatory.log
  #   {"event":"request","route":"/steam/achievements/:id","duration_ms":14472.1,
  #    "query_count":86359,"cached_query_count":84079,"cached_query_ratio":0.9736,
  #    "db_duration_ms":2104.3,"estimated_gc_time_ms":1832.0,…}
  #
  # One line per retained execution, one JSON object per line, no multi-line
  # records — so `grep`, `jq` and `tail -f` all work, and a truncated write costs
  # one record rather than corrupting the file.
  #
  # The summary line is deliberately flat and small; query groups are attached
  # separately and only for executions that had something worth grouping, so a
  # dull request costs one short line.
  #
  module LogSink

    # Query groups worth writing alongside the summary.
    # A dull execution logs no groups at all.
    #
    MAX_LOGGED_GROUPS = 5

    module_function

    # Write one retained execution.
    #
    # @param payload [Hash] a {Observatory::Serializer} result.
    #
    # @return [void]
    #
    def write(payload)
      Safely.call("log_sink.write") do
        line = summary(payload)
        groups = notable_groups(payload)
        line[:query_groups] = groups if groups.any?

        Observatory.logger.info(JSON.generate(line))
      end

      nil
    end

    # Build the flat summary object.
    #
    # Nil values are dropped so a dull request logs a short line rather than
    # forty explicit nulls. Everything else in the trace is written, including
    # the anonymised client identifier — it is an HMAC with a rotating salt, not
    # an address, and being able to `jq 'select(.client_id == "…")'` across a log
    # is how crawler amplification gets attributed before any dashboard exists.
    #
    # @param payload [Hash] a {Observatory::Serializer} result.
    #
    # @return [Hash{Symbol => Object}]
    #
    def summary(payload)
      trace = payload[:trace].compact

      { event: payload[:kind].to_s }.merge(trace)
    end

    # The query groups worth attaching to a log line.
    #
    # Only groups that actually repeated are written: a request issuing twelve
    # different queries once each is not a finding, and logging its twelve groups
    # would bury the one that is.
    #
    # @param payload [Hash] a {Observatory::Serializer} result.
    #
    # @return [Array<Hash>]
    #
    def notable_groups(payload)
      Array(payload[:query_groups])
        .select { |group| group[:count] > 1 }
        .first(MAX_LOGGED_GROUPS)
        .map do |group|
          {
            fingerprint: group[:fingerprint],
            count:       group[:count],
            cached:      group[:cached_count],
            duration_ms: group[:duration_ms],
            call_site:   group[:call_site],
          }.compact
        end
    end
  end
end
