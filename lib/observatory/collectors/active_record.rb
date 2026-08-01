# frozen_string_literal: true

module Observatory
  module Collectors

    # The `sql.active_record` subscriber — the busiest code in the system.
    #
    # On the request this product exists to explain, this runs 86,359 times. That
    # number sets every design constraint here:
    #
    # - it subscribes with the five-argument block form, which does **not**
    #   allocate an `ActiveSupport::Notifications::Event` per notification;
    # - it uses `monotonic_subscribe`, so durations survive a clock step;
    # - it does no I/O, no string building and no allocation in the common path
    #   beyond what fingerprinting requires;
    # - it returns after two hash reads when Observatory is off or suppressed.
    #
    # ## Separating cache hits from real queries
    #
    # The payload distinguishes them for us: ActiveRecord's query cache emits its
    # own `sql.active_record` notification carrying `cached: true`
    # (`active_record/connection_adapters/abstract/query_cache.rb`), while a real
    # execution does not set the key at all. That single boolean is what lets
    # Observatory say "84,079 of these never reached MySQL" — and therefore why
    # the database dashboard stayed green while the application burned.
    #
    module ActiveRecord
      SQL         = "sql.active_record".freeze
      INSTANTIATE = "instantiation.active_record".freeze
      MILLISECOND = 1_000.0

      class << self

        # Attach the ActiveRecord subscribers.
        #
        # @return [Array<Object>] the subscriber handles, for {detach}.
        #
        def install!
          @subscribers ||= [
            ActiveSupport::Notifications.monotonic_subscribe(SQL, &method(:on_query)),
            ActiveSupport::Notifications.monotonic_subscribe(INSTANTIATE, &method(:on_instantiation)),
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

      private

        # Fold one query into the execution in progress.
        #
        # @param _name [String] the notification name.
        # @param started [Float] monotonic start.
        # @param finished [Float] monotonic finish.
        # @param _id [String] the notification id.
        # @param payload [Hash] ActiveRecord's payload.
        #
        # @return [void]
        #
        def on_query(_name, started, finished, _id, payload)
          return if Instrumentation.suppressed?

          context = Current.execution
          return if context.nil?

          Safely.call("collectors.active_record.sql") do
            context.record_query(
              sql:         payload[:sql] || "",
              name:        payload[:name],
              duration_ms: (finished - started) * MILLISECOND,
              cached:      payload[:cached] ? true : false,
              rows:        payload[:row_count].to_i,
              async:       payload[:async] ? true : false,
            )
          end

          nil
        end

        # Fold a materialisation count into the execution in progress.
        #
        # High instantiation with low query count is a different shape from high
        # query count with low instantiation — the first is one query returning
        # too much, the second is too many queries. Recording both keeps them
        # distinguishable.
        #
        # @param _name [String] the notification name.
        # @param _started [Float] monotonic start.
        # @param _finished [Float] monotonic finish.
        # @param _id [String] the notification id.
        # @param payload [Hash] ActiveRecord's payload.
        #
        # @return [void]
        #
        def on_instantiation(_name, _started, _finished, _id, payload)
          return if Instrumentation.suppressed?

          context = Current.execution
          return if context.nil?

          context.record_instantiation(payload[:record_count].to_i)

          nil
        end
      end
    end
  end
end
