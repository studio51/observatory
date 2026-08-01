# frozen_string_literal: true

module Observatory

  # The per-execution context slot.
  #
  # {ActiveSupport::CurrentAttributes} is the right mechanism here rather than a
  # thread-local or a global: it is fiber-safe, and the Rails executor resets it
  # at the end of every request *and* every Sidekiq job. That last property is
  # what stops a context leaking from one unit of work into the next — the
  # failure this application already had to fix once for `RequestStore` (see
  # `SidekiqRequestStoreMiddleware`), and which would be far more damaging here
  # because a leaked context would attribute one request's queries to another.
  #
  class Current < ActiveSupport::CurrentAttributes
    attribute :execution   # the Observatory::Execution in progress, or nil

    class << self

      # The execution in progress, if Observatory is collecting one.
      #
      # Subscribers call this on every notification, so it must stay a plain
      # attribute read.
      #
      # @return [Observatory::Execution::Base, nil]
      #
      def context
        execution
      end

      # Run a block with the given execution installed as the current context.
      #
      # Always restores the previous context, so nesting (a job enqueued and run
      # inline inside a request, for instance) cannot orphan the outer one.
      #
      # @param context [Observatory::Execution::Base] the execution to install.
      #
      # @yield the instrumented work.
      #
      # @return [Object] whatever the block returns.
      #
      def with(context)
        previous = execution
        self.execution = context

        yield
      ensure
        self.execution = previous
      end
    end
  end
end
