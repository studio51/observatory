# frozen_string_literal: true

module Observatory

  # The overview: the whole system's state on one page.
  #
  # ## The design brief for this page in one sentence
  #
  # Every infrastructure panel is allowed to be green while a single central
  # panel is red, because that combination *is* the incident. A dashboard that
  # cannot show "MySQL fine, Redis fine, CPU fine, and the application is
  # nonetheless out of capacity" cannot describe what actually happens.
  #
  # So the layout is deliberate: the dependency panels are small, calm and
  # factual, and the finding sits above them at full width. The eye should be
  # drawn to the conclusion, not to a wall of sparklines.
  #
  class DashboardsController < ApplicationController

    # @return [void]
    #
    def show
      @capacity   = ProcessSample.capacity_now
      @incidents  = Incident.open_incidents.by_severity.includes(:evidence).limit(10)
      @headline   = @incidents.first
      @traffic    = traffic_summary
      @mysql      = DependencySample.latest(DependencySample::MYSQL)
      @redis      = DependencySample.latest(DependencySample::REDIS)
      @queues     = DependencySample.latest_queues
      @workers    = ProcessSample.latest_per_process(role: ProcessSample::WEB)
      @sidekiq    = ProcessSample.latest_per_process(role: ProcessSample::SIDEKIQ)
      @deployment = Deployment.recent_first.first
      @watchdog   = WatchdogEvent.recent_first.first
      @health     = Runtime.health
      @top_routes = window.routes.sort_by { |_endpoint, m| -m[:thread_seconds] }.first(8)
      @long       = RequestTrace.between(@from, @to)
                                .where(duration_ms: (Observatory.config.extreme_request_threshold * 1_000)..)
                                .order(duration_ms: :desc).limit(10)
    end

  private

    # Traffic, latency and error rate for the window, from rollups so the counts
    # are true rather than extrapolated from the trace sample.
    #
    # @return [Hash{Symbol => Object}]
    #
    def traffic_summary
      rollups = window.route_rollups
      count = rollups.sum(&:count)
      histogram = rollups.each_with_object(Histogram.empty) { |r, h| Histogram.merge(h, r.duration_histogram) }

      {
        requests:       count,
        per_second:     (window.span.positive? ? (count / window.span).round(2) : 0.0),
        errors:         rollups.sum(&:error_count),
        error_rate:     (count.positive? ? rollups.sum(&:error_count).to_f / count : 0.0),
        p50:            Histogram.percentile(histogram, 0.50, count),
        p95:            Histogram.percentile(histogram, 0.95, count),
        p99:            Histogram.percentile(histogram, 0.99, count),
        thread_seconds: rollups.sum(&:thread_seconds),
        queries:        rollups.sum(&:query_count_sum),
        cached_ratio:   cached_ratio(rollups),
        crawlers:       rollups.sum(&:crawler_count),
      }
    end

    # @param rollups [Array<Observatory::RouteRollup>] the window's rollups.
    #
    # @return [Float] 0.0-1.0.
    #
    def cached_ratio(rollups)
      queries = rollups.sum(&:query_count_sum)
      return 0.0 if queries.zero?

      rollups.sum(&:cached_query_count_sum).to_f / queries
    end
  end
end
