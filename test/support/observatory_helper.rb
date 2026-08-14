# frozen_string_literal: true

# Test support for Observatory.
#
# Observatory is disabled in the test environment (see
# `config/initializers/observatory.rb`) so the suite is not busy measuring
# itself — 3,000 tests each producing traces would be noise, and the parallel
# workers would contend on the buffer. Tests that need it opt in explicitly.
#
#   test "a controller request produces a trace" do
#     trace = with_observatory { get root_path }
#     assert_equal 200, trace[:trace][:status]
#   end
#
module ObservatoryHelper

  # Run the block with Observatory collecting.
  #
  # Restores the previous configuration afterwards, so a test that changes a
  # threshold cannot leak it into the next test — which matters more than usual
  # here because the suite runs in parallel workers that share process state.
  #
  # @param overrides [Hash{Symbol => Object}] configuration to apply for the block.
  #
  # @yield the work to measure.
  #
  # @return [Object] whatever the block returns.
  #
  def with_observatory(**overrides)
    previous = capture_observatory_config

    Observatory.config.enabled     = true
    Observatory.config.persist     = false
    Observatory.config.log_events  = false
    Observatory.config.synchronous = true
    Observatory.config.normal_request_sample_rate = 1.0
    Observatory.config.normal_job_sample_rate     = 1.0
    overrides.each { |key, value| Observatory.config.public_send(:"#{key}=", value) }

    yield
  ensure
    restore_observatory_config(previous)
    Observatory::Capacity.reset!
    Observatory::Sampling::Decision.reset!
    Observatory::Pipeline.reset!
  end

  # Run the block and return every execution Observatory retained.
  #
  # Captures through the real logger rather than by stubbing the sink, so a test
  # asserting on collection is also asserting that the payload survives JSON
  # serialisation — which is where a non-serialisable value (an ActiveRecord
  # object accidentally left in a payload, say) would otherwise only show up in
  # production.
  #
  # @param overrides [Hash{Symbol => Object}] configuration to apply for the block.
  #
  # @yield the work to measure.
  #
  # @return [Array<Hash>] the logged executions, symbol-keyed, in completion order.
  #
  def capture_observatory_payloads(**overrides, &block)
    lines = []
    logger = Object.new
    logger.define_singleton_method(:info) { |line| lines << line }
    logger.define_singleton_method(:error) { |_line| nil }

    with_observatory(log_events: true, logger:, **overrides, &block)

    lines.map { |line| JSON.parse(line, symbolize_names: true) }
  end

  # Run the block inside a synthetic request context and return its trace.
  #
  # For unit-testing collection without going through the full Rack stack.
  #
  # @param route [String] the route template to attribute the work to.
  # @param overrides [Hash{Symbol => Object}] configuration to apply for the block.
  #
  # @yield the work to measure.
  #
  # @return [Observatory::Execution::Request] the finished, unsubmitted execution.
  #
  def observe_request(route: "/test/:id", **overrides)
    context = nil

    with_observatory(**overrides) do
      context = Observatory::Execution::Request.new(
        trace_id: Observatory::Trace.generate, request_id: "test-request",
        http_method: "GET", path: "/test/1",
      )
      context.resolve_route(controller: "TestController", action: "show", route:)

      Observatory::Current.with(context) do
        Observatory::Capacity.enter(context)

        begin
          yield context
        ensure
          Observatory::Capacity.leave(context)
        end
      end

      context.complete!(status: 200)
    end

    context
  end

private

  # @return [Hash{Symbol => Object}] every configuration attribute and its value.
  #
  def capture_observatory_config
    config = Observatory.config

    config.public_methods(false).grep(/=\z/).each_with_object({}) do |writer, captured|
      reader = writer.to_s.delete_suffix("=").to_sym
      captured[reader] = config.public_send(reader) if config.respond_to?(reader)
    end
  end

  # @param captured [Hash{Symbol => Object}] a {capture_observatory_config} result.
  #
  # @return [void]
  #
  def restore_observatory_config(captured)
    captured.each { |attribute, value| Observatory.config.public_send(:"#{attribute}=", value) }

    nil
  end
end
