# frozen_string_literal: true

module Observatory

  # Assembles an incident's causal timeline.
  #
  # ## Why a timeline instead of a row of graphs
  #
  # Six unrelated charts on one page leave the reader to do the correlation, and
  # correlation across charts at three in the morning is exactly the task people
  # get wrong. The incident is a *sequence*, and reading it as one is what makes
  # the cause obvious:
  #
  #   13:40:02  crawler begins achievement traversal
  #   13:40:11  cached query count rises
  #   13:40:14  puma worker 2 reaches 100% thread utilisation
  #   13:40:18  request backlog begins
  #   13:40:31  /up exceeds the health-check timeout
  #   13:41:02  watchdog records its third failed probe
  #   13:41:03  puma hot restart issued
  #   13:41:07  in-flight requests dropped
  #   13:41:10  health returns
  #
  # Nobody needs the causal chain explained after reading that.
  #
  # Every entry is derived from a stored record with its own timestamp — nothing
  # here is inferred or interpolated, so each line can be clicked through to the
  # thing that produced it.
  #
  module Timeline

    # One moment on the timeline.
    #
    Entry = Struct.new(
      :at,        # Time: when it happened
      :kind,      # Symbol: :deployment, :request, :saturation, :health_check, :watchdog, :incident
      :summary,   # String: one line, written for a human
      :severity,  # Symbol: :critical, :warning or :info
      :subject,   # Object, nil: the record it came from, for linking
      keyword_init: true,
    )

    module_function

    # Build the timeline for an incident.
    #
    # @param incident [Observatory::Incident] the incident.
    # @param padding [ActiveSupport::Duration] how far either side of it to look.
    #
    # @return [Array<Observatory::Timeline::Entry>] chronological.
    #
    def for(incident, padding: 5.minutes)
      from = incident.started_at - padding
      to   = (incident.ended_at || incident.last_seen_at) + padding

      entries = [ opened(incident) ]
      entries.concat(deployments(from, to))
      entries.concat(long_requests(incident, from, to))
      entries.concat(saturation(from, to))
      entries.concat(health_checks(from, to))
      entries.concat(watchdog_events(from, to))
      entries << closed(incident) if incident.ended_at

      entries.compact.sort_by(&:at)
    end

    # @param incident [Observatory::Incident] the incident.
    #
    # @return [Observatory::Timeline::Entry]
    #
    def opened(incident)
      Entry.new(at: incident.started_at, kind: :incident, severity: incident.severity.to_sym,
                summary: "Incident opened: #{incident.title}", subject: incident)
    end

    # @param incident [Observatory::Incident] the incident.
    #
    # @return [Observatory::Timeline::Entry]
    #
    def closed(incident)
      Entry.new(at: incident.ended_at, kind: :incident, severity: :info,
                summary: "Incident resolved", subject: incident)
    end

    # @param from [Time] the start of the window.
    # @param to [Time] the end of the window.
    #
    # @return [Array<Observatory::Timeline::Entry>]
    #
    def deployments(from, to)
      Deployment.where(deployed_at: from..to).map do |deployment|
        Entry.new(at: deployment.deployed_at, kind: :deployment, severity: :info,
                  summary: "Deployed #{deployment.label}", subject: deployment)
      end
    end

    # The requests that were expensive enough to matter, one entry each.
    #
    # @param incident [Observatory::Incident] the incident.
    # @param from [Time] the start of the window.
    # @param to [Time] the end of the window.
    #
    # @return [Array<Observatory::Timeline::Entry>]
    #
    def long_requests(incident, from, to)
      threshold = Observatory.config.extreme_request_threshold * 1_000

      RequestTrace.between(from, to)
                  .where(duration_ms: threshold..)
                  .order(duration_ms: :desc)
                  .limit(15)
                  .map do |trace|
        detail = "#{(trace.duration_ms / 1_000.0).round(1)}s"
        detail += ", #{number(trace.query_count)} lookups" if trace.query_count.positive?
        detail += " (#{(trace.cached_query_ratio * 100).round}% cached)" if trace.cached_query_ratio > 0.5

        Entry.new(at: trace.started_at, kind: :request,
                  severity: trace.incident_id == incident.id ? :critical : :warning,
                  summary: "#{trace.endpoint} — #{detail}", subject: trace)
      end
    end

    # Saturation as two entries — when it began and when it cleared — rather than
    # one per fifteen-second sample, which would bury everything else.
    #
    # @param from [Time] the start of the window.
    # @param to [Time] the end of the window.
    #
    # @return [Array<Observatory::Timeline::Entry>]
    #
    def saturation(from, to)
      samples = ProcessSample.between(from, to).web.chronological.to_a
      entries = []
      inside = false

      samples.each do |sample|
        if sample.saturated? && !inside
          inside = true
          entries << Entry.new(
            at: sample.sampled_at, kind: :saturation, severity: :critical,
            summary: "Puma worker #{sample.worker_index || sample.process_id} reached " \
                     "#{sample.busy_threads}/#{sample.max_threads} threads" \
                     "#{" — backlog #{sample.backlog}" if sample.backlog.to_i.positive?}",
            subject: sample,
          )
        elsif !sample.saturated? && inside
          inside = false
          entries << Entry.new(at: sample.sampled_at, kind: :saturation, severity: :info,
                               summary: "Request capacity recovered", subject: sample)
        end
      end

      entries
    end

    # @param from [Time] the start of the window.
    # @param to [Time] the end of the window.
    #
    # @return [Array<Observatory::Timeline::Entry>]
    #
    def health_checks(from, to)
      RequestTrace.between(from, to).health_checks.recent_first.limit(20).filter_map do |check|
        next if check.status.to_i == 200 && check.duration_ms < 1_000

        Entry.new(at: check.started_at, kind: :health_check, severity: :critical,
                  summary: "#{check.endpoint} took #{(check.duration_ms / 1_000.0).round(1)}s" \
                           "#{" and returned #{check.status}" if check.status.to_i != 200}",
                  subject: check)
      end
    end

    # @param from [Time] the start of the window.
    # @param to [Time] the end of the window.
    #
    # @return [Array<Observatory::Timeline::Entry>]
    #
    def watchdog_events(from, to)
      WatchdogEvent.between(from, to).map do |event|
        summary = "Watchdog: #{event.trigger}"
        summary += " → #{event.action_taken}" if event.action_taken.present?
        summary += " (Observatory: #{event.recommended_action})" if event.disagreed?

        Entry.new(at: event.occurred_at, kind: :watchdog,
                  severity: event.disagreed? ? :critical : :warning,
                  summary:, subject: event)
      end
    end

    # @param value [Numeric] the number to format.
    #
    # @return [String] with thousands separators.
    #
    def number(value)
      value.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end
  end
end
