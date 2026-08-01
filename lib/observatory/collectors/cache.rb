# frozen_string_literal: true

module Observatory
  module Collectors

    # Subscribers for `Rails.cache`.
    #
    # Distinct from the ActiveRecord query cache, and the distinction matters
    # enough to spell out: `Rails.cache` is Redis, so its work costs a network
    # round trip and shows up as time. The ActiveRecord query cache is a hash in
    # process memory, so its work costs *no* time downstream and shows up
    # nowhere — which is exactly why a request can perform eighty-four thousand
    # cached lookups while every dependency dashboard stays flat.
    #
    # Observatory measures both, separately, and never conflates them.
    #
    module Cache
      EVENTS = {
        "cache_read.active_support"       => :read,
        "cache_read_multi.active_support" => :read_multi,
        "cache_write.active_support"      => :write,
        "cache_delete.active_support"     => :delete,
        "cache_fetch_hit.active_support"  => :fetch_hit,
      }.freeze

      MILLISECOND = 1_000.0

      class << self

        # Attach the cache subscribers.
        #
        # @return [Array<Object>] the subscriber handles, for {detach}.
        #
        def install!
          @subscribers ||= EVENTS.map do |event, operation|
            ActiveSupport::Notifications.monotonic_subscribe(event) do |_name, started, finished, _id, payload|
              record(operation, started, finished, payload)
            end
          end
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

        # Fold one cache operation into the execution in progress.
        #
        # @param operation [Symbol] :read, :read_multi, :write, :delete or :fetch_hit.
        # @param started [Float] monotonic start.
        # @param finished [Float] monotonic finish.
        # @param payload [Hash] ActiveSupport's payload.
        #
        # @return [void]
        #
        def record(operation, started, finished, payload)
          return if Instrumentation.suppressed?

          context = Current.execution
          return if context.nil?

          # `cache_fetch_hit` has no duration of its own — it is emitted inside
          # the surrounding `cache_read`, which already accounted for the time.
          #
          duration = operation == :fetch_hit ? 0.0 : (finished - started) * MILLISECOND

          context.record_cache(operation, duration, hit: payload[:hit])

          nil
        end
      end
    end
  end
end
