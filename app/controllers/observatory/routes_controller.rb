# frozen_string_literal: true

module Observatory

  # Routes, ranked by the request capacity they consume.
  #
  # Sorted by thread-seconds rather than request count by default, because that
  # is the ordering that identifies the capacity risk: a route called ten times
  # for twenty seconds outranks one called a thousand times for twenty
  # milliseconds, and the request-count ordering says the opposite.
  #
  class RoutesController < ApplicationController

    # @return [void]
    #
    def index
      @routes = window.routes.sort_by { |_endpoint, m| -m[sort_column] }
      @baselines = window.baselines
    end

    # @return [void]
    #
    def show
      @endpoint  = params[:endpoint].to_s
      @rollups   = RouteRollup.minutes.for_endpoint(@endpoint).between(@from, @to).chronological
      @baseline  = window.baseline_for(@endpoint)
      @summary   = window.routes[@endpoint]
      @traces    = RequestTrace.for_endpoint(@endpoint).between(@from, @to)
                               .order(duration_ms: :desc).limit(25)
      @shapes    = top_query_shapes
      @incidents = Incident.where(primary_contributor: @endpoint).recent_first.limit(10)
    end

  private

    # @return [Symbol] the measurement to rank by.
    #
    helper_method def sort_column
      allowed = %i[thread_seconds count duration_sum_ms query_count_sum allocation_sum error_count]

      allowed.include?(params[:sort]&.to_sym) ? params[:sort].to_sym : :thread_seconds
    end

    # The query shapes this route issues most, across every retained trace.
    #
    # Grouped by fingerprint digest so the same shape from different requests is
    # one row — which is the whole point of fingerprinting.
    #
    # @return [Array<Hash>]
    #
    def top_query_shapes
      trace_ids = RequestTrace.for_endpoint(@endpoint).between(@from, @to).limit(500).pluck(:id)
      return [] if trace_ids.empty?

      QueryGroup.where(trace_kind: QueryGroup::REQUEST, trace_row_id: trace_ids)
                .group(:fingerprint_digest)
                .pluck(Arel.sql("fingerprint_digest"), Arel.sql("MAX(fingerprint)"),
                       Arel.sql("SUM(count)"), Arel.sql("SUM(cached_count)"),
                       Arel.sql("SUM(duration_ms)"), Arel.sql("MAX(call_site)"))
                .map do |digest, fingerprint, total, cached, duration, call_site|
                  { digest:, fingerprint:, count: total.to_i, cached: cached.to_i,
                    duration_ms: duration.to_f, call_site:, }
                end
                .sort_by { |shape| -shape[:count] }
                .first(20)
    end
  end
end
