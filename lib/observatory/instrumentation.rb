# frozen_string_literal: true

module Observatory

  # Instrumentation suppression — the mechanism that stops Observatory watching
  # itself.
  #
  # Every write Observatory performs is an ActiveRecord query, every rollup it
  # computes is a set of ActiveRecord queries, and every retention sweep is a
  # `delete_all`. Without suppression those would be collected by the very
  # subscribers that produced them, and a monitoring flush would look like a
  # query explosion — or, worse, recurse.
  #
  # The rule is absolute: **every subscriber, middleware and probe returns
  # immediately when suppressed.** Wrap anything Observatory does on its own
  # behalf:
  #
  #   Observatory::Instrumentation.suppress do
  #     Observatory::RequestTrace.insert_all(rows)
  #   end
  #
  # State is held in {ActiveSupport::IsolatedExecutionState}, which is
  # fiber-safe and reset by the Rails executor at the end of each request and
  # job — so a suppression leaked by a raised exception cannot outlive the unit
  # of work that leaked it. The counter is a depth, not a flag, so nesting is
  # safe.
  #
  module Instrumentation
    KEY = :observatory_suppression_depth # IsolatedExecutionState slot holding the nesting depth

    class << self

      # Run the block with all Observatory instrumentation disabled.
      #
      # Re-entrant: nested calls increment a depth counter and only the outermost
      # exit re-enables collection. The previous depth is always restored, even
      # when the block raises.
      #
      # @yield the work to perform uninstrumented.
      #
      # @return [Object] whatever the block returns.
      #
      def suppress
        previous = ActiveSupport::IsolatedExecutionState[KEY].to_i
        ActiveSupport::IsolatedExecutionState[KEY] = previous + 1

        yield
      ensure
        ActiveSupport::IsolatedExecutionState[KEY] = previous
      end

      # Whether instrumentation is currently suppressed on this execution context.
      #
      # This is the first line of every subscriber, so it is deliberately one
      # hash read and one integer comparison.
      #
      # @return [Boolean]
      #
      def suppressed?
        ActiveSupport::IsolatedExecutionState[KEY].to_i.positive?
      end

      # Mark the calling thread as permanently suppressed.
      #
      # Used by the batch writer and the probe sampler, which are Observatory's
      # own threads and must never collect. There is no matching "unsuppress" —
      # a thread that calls this is Observatory's for its whole life.
      #
      # @return [void]
      #
      def suppress_thread!
        ActiveSupport::IsolatedExecutionState[KEY] = 1

        nil
      end
    end
  end
end
