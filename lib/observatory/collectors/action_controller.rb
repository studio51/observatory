# frozen_string_literal: true

module Observatory
  module Collectors

    # Subscribers for the controller and view layers.
    #
    # These fire once per request rather than once per query, so they can afford
    # to do slightly more work. Their job is to give a trace its *identity*: the
    # route template, the controller, the action.
    #
    # ## Why the route template and not the path
    #
    # `/steam/achievements/839292` is useless for analysis. It cannot be grouped,
    # so it has no baseline; it cannot be compared, so it has no regression; and
    # it carries an identifier that need not be stored. `/steam/achievements/:id`
    # does all three jobs and carries nothing. Rails 8 exposes the template
    # directly through `ActionDispatch::Request#route_uri_pattern`, which reads
    # the route the router actually matched rather than guessing from the path.
    #
    module ActionController
      PROCESS_ACTION  = "process_action.action_controller".freeze
      RENDER_TEMPLATE = "render_template.action_view".freeze
      RENDER_PARTIAL  = "render_partial.action_view".freeze
      RENDER_LAYOUT   = "render_layout.action_view".freeze
      FORMAT_SUFFIX   = "(.:format)".freeze
      MILLISECOND     = 1_000.0

      class << self

        # Attach the controller and view subscribers.
        #
        # @return [Array<Object>] the subscriber handles, for {detach}.
        #
        def install!
          @subscribers ||= [
            ActiveSupport::Notifications.monotonic_subscribe(PROCESS_ACTION, &method(:on_process_action)),
            ActiveSupport::Notifications.monotonic_subscribe(RENDER_TEMPLATE, &method(:on_render)),
            ActiveSupport::Notifications.monotonic_subscribe(RENDER_LAYOUT, &method(:on_render)),
          ]
        end

        # Remove the subscribers. Test-suite hygiene only.
        #
        # @return [void]
        #
        def detach!
          Array(@subscribers).each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
          @subscribers = nil

          nil
        end

        # Normalise a Rails route pattern into the form used for grouping.
        #
        # Strips the optional format segment, because `/steam/achievements/:id`
        # and `/steam/achievements/:id.json` are the same endpoint for capacity
        # purposes and splitting them would halve every baseline.
        #
        # @param pattern [String, nil] the raw route pattern.
        #
        # @return [String, nil] the normalised template.
        #
        def normalise_route(pattern)
          return nil if pattern.nil? || pattern.empty?

          pattern.delete_suffix(FORMAT_SUFFIX)
        end

      private

        # Record what the router resolved for this request.
        #
        # Runs inside the request, so `Current.execution` is the request's own
        # context and no correlation is needed.
        #
        # @param _name [String] the notification name.
        # @param _started [Float] monotonic start.
        # @param _finished [Float] monotonic finish.
        # @param _id [String] the notification id.
        # @param payload [Hash] ActionController's payload.
        #
        # @return [void]
        #
        def on_process_action(_name, _started, _finished, _id, payload)
          return if Instrumentation.suppressed?

          context = Current.execution
          return unless context.is_a?(Execution::Request)

          Safely.call("collectors.action_controller.process_action") do
            context.resolve_route(
              controller: payload[:controller],
              action:     payload[:action],
              route:      route_for(payload),
            )

            # ActionController reports view time in milliseconds already, and its
            # figure covers the whole render including layouts and partials —
            # more complete than summing the individual render notifications.
            #
            view_runtime = payload[:view_runtime]
            context.record_view(view_runtime) if view_runtime
          end

          nil
        end

        # Record view time for renders that happen outside a controller action —
        # a mailer, or a component rendered from a job.
        #
        # Skipped when the controller already reported `view_runtime`, so the two
        # sources cannot double-count.
        #
        # @param _name [String] the notification name.
        # @param started [Float] monotonic start.
        # @param finished [Float] monotonic finish.
        # @param _id [String] the notification id.
        # @param _payload [Hash] ActionView's payload.
        #
        # @return [void]
        #
        def on_render(_name, started, finished, _id, _payload)
          return if Instrumentation.suppressed?

          context = Current.execution
          return if context.nil?
          return if context.is_a?(Execution::Request)

          context.record_view((finished - started) * MILLISECOND)

          nil
        end

        # The matched route template, when the router recorded one.
        #
        # @param payload [Hash] ActionController's payload, carrying the request.
        #
        # @return [String, nil]
        #
        def route_for(payload)
          request = payload[:request]
          return nil unless request.respond_to?(:route_uri_pattern)

          normalise_route(request.route_uri_pattern)
        end
      end
    end
  end
end
