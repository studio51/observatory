# frozen_string_literal: true

module Observatory

  # Incidents, and one incident's causal timeline.
  #
  class IncidentsController < ApplicationController

    # @return [void]
    #
    def index
      @open     = Incident.open_incidents.by_severity.includes(:evidence)
      @resolved = Incident.resolved.recent_first.limit(50)
    end

    # @return [void]
    #
    def show
      @incident   = Incident.find(params[:id])
      @traces     = @incident.request_traces.recent_first.limit(20)
      @jobs       = @incident.job_traces.recent_first.limit(20)
      @events     = @incident.watchdog_events.recent_first
      @deployment = @incident.deployment || @incident.correlated_deployment
      @timeline   = Timeline.for(@incident)
    end

    # Re-run detection now rather than waiting for the next cycle.
    #
    # @return [void]
    #
    def analyse
      Analysis::Engine.run!(window)

      redirect_to incidents_path(carried_params), notice: "Analysis complete."
    end

    # @return [void]
    #
    def resolve
      incident = Incident.find(params[:id])
      incident.resolve!(notes: params[:notes].presence)

      redirect_to incident_path(incident, **carried_params), notice: "Incident resolved."
    end
  end
end
