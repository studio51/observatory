# frozen_string_literal: true

module Observatory

  # The request explorer, and one request in detail.
  #
  # Filters are plain query parameters against scopes on {RequestTrace}, rendered
  # inside a Turbo Frame — the house convention here is HTML over the wire, and
  # a filterable table is exactly what Turbo Frames are for.
  #
  class RequestsController < ApplicationController
    PER_PAGE = 50

    # @return [void]
    #
    def index
      @traces = filtered.recent_first.limit(PER_PAGE)
      @total  = filtered.limit(10_000).count
    end

    # @return [void]
    #
    def show
      @trace  = RequestTrace.find(params[:id])
      @groups = @trace.query_groups.most_repeated
      @concurrent = @trace.concurrent_requests_in_process
      @incident = @trace.incident
      @capacity = ProcessSample.where(process_id: @trace.process_id, hostname: @trace.hostname)
                               .between(@trace.started_at - 60, @trace.started_at + 60)
                               .chronological
    end

  private

    # Apply every filter present in the query string.
    #
    # Each is a named scope, so the filter set is the model's vocabulary rather
    # than ad-hoc SQL assembled in a controller.
    #
    # @return [ActiveRecord::Relation]
    #
    def filtered
      scope = RequestTrace.between(@from, @to)
      scope = scope.for_endpoint(params[:endpoint]) if params[:endpoint].present?
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.errored if params[:only] == "errors"
      scope = scope.slow if params[:only] == "slow"
      scope = scope.cached_query_explosions if params[:only] == "cached_explosions"
      scope = scope.query_heavy if params[:only] == "query_heavy"
      scope = scope.crawlers if params[:only] == "crawlers"
      scope = scope.health_checks if params[:only] == "health_checks"
      scope = scope.by_traffic_class(params[:traffic_class]) if params[:traffic_class].present?
      scope = scope.for_client(params[:client_id]) if params[:client_id].present?
      scope = scope.for_release(params[:release]) if params[:release].present?
      scope = scope.where(incident_id: params[:incident_id]) if params[:incident_id].present?
      scope = scope.where(trace_id: params[:trace_id]) if params[:trace_id].present?
      scope = scope.where(duration_ms: (params[:min_duration].to_f * 1_000)..) if params[:min_duration].present?
      scope = scope.where(query_count: params[:min_queries].to_i..) if params[:min_queries].present?

      scope
    end

    # The filters currently applied, for the view's chips and for carrying
    # across links.
    #
    # @return [Hash{Symbol => Object}]
    #
    helper_method def filters
      params.permit(:endpoint, :status, :only, :traffic_class, :client_id, :release,
                    :incident_id, :trace_id, :min_duration, :min_queries, :period)
            .to_h.symbolize_keys.compact_blank
    end
  end
end
