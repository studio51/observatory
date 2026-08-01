# frozen_string_literal: true

require "observatory/histogram"
require "observatory/pipeline/buffer"
require "observatory/pipeline/aggregator"
require "observatory/pipeline/writer"

module Observatory

  # Where a finished execution goes.
  #
  # The whole path from "the response has been sent" to "a row exists" runs here,
  # and it runs *after* the work it describes. Nothing in this module is on the
  # critical path of a request: {submit} is called from the Rack middleware's
  # `ensure`, after the status and headers are settled, and its expensive half
  # (the database write) happens on a different thread entirely.
  #
  #   execution → sample decision → serialise → log → bounded buffer → writer thread
  #
  # Everything is wrapped in {Observatory::Safely}, so a failure anywhere in this
  # chain costs a counter increment and a rate-limited log line, never a request.
  #
  module Pipeline
    module_function

    # Retire a finished execution.
    #
    # @param execution [Observatory::Execution::Base] the finished execution.
    #
    # @return [void]
    #
    def submit(execution)
      return unless Observatory.config.enabled?

      Safely.call("pipeline.submit") do
        decision = Sampling::Decision.call(execution)

        # Rollups see *every* execution, traces only the sampled ones. Counting
        # rates from a 1% sample of a skewed distribution produces confident
        # nonsense; this is the line that stops that happening.
        #
        Aggregator.record(execution, retained: decision.keep?)

        next unless decision.keep?

        payload = Serializer.call(execution, decision)

        LogSink.write(payload) if Observatory.config.log_events
        store(payload, decision) if Observatory.config.persist?
      end

      nil
    end

    # The process-wide buffer between collection and persistence.
    #
    # @return [Observatory::Pipeline::Buffer]
    #
    def buffer
      @buffer ||= Buffer.new
    end

    # Replace the buffer. Test-suite hygiene only.
    #
    # @return [void]
    #
    def reset!
      @buffer = nil

      nil
    end

    # Hand a serialised execution to the writer.
    #
    # In synchronous mode (tests) the write happens inline so an assertion can
    # read the row immediately. Everywhere else it goes into the bounded buffer
    # and a background thread drains it.
    #
    # @param payload [Hash] a {Observatory::Serializer} result.
    # @param decision [Observatory::Sampling::Decision::Result] why it was retained.
    #
    # @return [void]
    #
    def store(payload, decision)
      return Writer.write_now([ payload ]) if Observatory.config.synchronous

      buffer.push(payload, priority: priority_for(decision))

      nil
    end

    # How hard the buffer should fight to keep this event under pressure.
    #
    # The mapping is the product decision made concrete: when the buffer is full
    # during an incident, the events describing the incident are the ones that
    # survive.
    #
    # @param decision [Observatory::Sampling::Decision::Result] why it was retained.
    #
    # @return [Symbol] :normal, :high or :critical.
    #
    def priority_for(decision)
      return :critical if decision.retention_class == :error
      return :critical if (decision.reasons & CRITICAL_REASONS).any?
      return :high if decision.retention_class == :anomalous

      :normal
    end

    # Retention reasons that make an event worth evicting other events for.
    #
    CRITICAL_REASONS = %i[exception server_error health_check_failure saturation marked].freeze
  end
end
