# frozen_string_literal: true

module Observatory

  # The base controller for the Observatory dashboard.
  #
  # ## Inheriting from the host
  #
  # Rather than defining its own authentication, this inherits from whatever the
  # host names in `Observatory.config.parent_controller`. In games.directory that
  # is `Admin::ApplicationController`, so the dashboard picks up the existing
  # `devops?` gate, the admin layout, the breadcrumbs and the flash types with no
  # duplication — and, more importantly, no second implementation of authorisation
  # that could drift from the first.
  #
  # An application that installs the gem without configuring it gets
  # `ActionController::Base` and must mount the engine behind its own constraint.
  # That default is deliberately inconvenient: an unprotected monitoring dashboard
  # exposes route templates, query shapes and traffic patterns, and it should take
  # a decision to get one.
  #
  # ## Everything here is suppressed
  #
  # Rendering the dashboard is itself a request making dozens of queries. Without
  # suppression the dashboard would appear in its own explorer as a query-heavy
  # route, and looking at the monitoring would degrade the monitoring.
  #
  class ApplicationController < Observatory.parent_controller

    # Inheriting from a host controller means Rails resolves helpers against the
    # *host's* helper path, not the engine's, so the engine's own helpers have to
    # be named explicitly. Without this the views raise `undefined method
    # observatory_duration`, which is a confusing way to learn it.
    #
    helper Observatory::DashboardHelper

    # The engine ships its own chrome rather than borrowing the host's admin
    # layout. See the layout itself for why: a gem cannot depend on a layout it
    # does not ship, and an isolated engine cannot resolve the host's route
    # helpers anyway.
    #
    layout "observatory/application"

    around_action :suppress_instrumentation
    before_action :set_time_range

    # The window every page reads from.
    #
    # @return [Observatory::Analysis::Window]
    #
    helper_method def window
      @window ||= Analysis::Window.new(from: @from, to: @to)
    end

    # The range currently being viewed, for the period picker.
    #
    # @return [String]
    #
    helper_method def period
      @period
    end

    # Known time ranges, and how far back each reaches.
    #
    PERIODS = {
      "15m" => 15.minutes, "1h" => 1.hour, "6h" => 6.hours,
      "24h" => 24.hours, "7d" => 7.days,
    }.freeze

  private

    # Keep the dashboard out of its own data.
    #
    # @yield renders the page.
    #
    # @return [void]
    #
    def suppress_instrumentation(&block)
      Instrumentation.suppress(&block)
    end

    # Resolve the requested time range.
    #
    # @return [void]
    #
    def set_time_range
      @period = PERIODS.key?(params[:period]) ? params[:period] : "1h"
      @to = Time.current
      @from = @to - PERIODS.fetch(@period)

      nil
    end

    # Parameters to carry across links so a filter survives navigation.
    #
    # @return [Hash{Symbol => Object}]
    #
    helper_method def carried_params
      { period: @period }.compact
    end
  end
end
