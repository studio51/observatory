# frozen_string_literal: true

require "test_helper"

module Observatory

  # Suppression and fail-open are the two properties that decide whether this
  # system is safe to run in production. Everything else is a feature; these are
  # the promises.
  #
  class InstrumentationTest < ActiveSupport::TestCase

    teardown do
      Safely.reset!
    end

    test "suppression stops collection inside the block" do
      assert_not Instrumentation.suppressed?

      Instrumentation.suppress do
        assert Instrumentation.suppressed?
      end

      assert_not Instrumentation.suppressed?
    end

    test "suppression nests and only the outermost exit re-enables collection" do
      Instrumentation.suppress do
        Instrumentation.suppress do
          assert Instrumentation.suppressed?
        end

        assert Instrumentation.suppressed?, "an inner block exiting must not re-enable collection"
      end

      assert_not Instrumentation.suppressed?
    end

    test "suppression is restored when the block raises" do
      assert_raises(RuntimeError) do
        Instrumentation.suppress { raise "boom" }
      end

      assert_not Instrumentation.suppressed?, "a raised block must not leak suppression"
    end

    test "a suppressed subscriber records nothing" do
      execution = Execution::Request.new(trace_id: "a", request_id: nil, http_method: "GET", path: "/x")

      Current.with(execution) do
        Instrumentation.suppress do
          ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1", name: "Load") { nil }
        end
      end

      assert_equal 0, execution.query_count
    end

    test "a monitoring write does not appear in the surrounding execution's tally" do
      Collectors::ActiveRecord.install!

      execution = Execution::Request.new(trace_id: "a", request_id: nil, http_method: "GET", path: "/x")

      Current.with(execution) do
        ActiveRecord::Base.connection.select_value("SELECT 1")

        Instrumentation.suppress do
          ActiveRecord::Base.connection.select_value("SELECT 2")
          ActiveRecord::Base.connection.select_value("SELECT 3")
        end
      end

      assert_equal 1, execution.query_count, "only the application's own query is counted"
    end

    test "Safely swallows an exception and returns the fallback" do
      result = Safely.call("test.boom", fallback: :fell_back) { raise ArgumentError, "nope" }

      assert_equal :fell_back, result
      assert_equal 1, Safely.failure_counts["test.boom"]
    end

    test "Safely swallows even a non-StandardError" do
      result = Safely.call("test.no_method", fallback: :safe) { nil.definitely_not_a_method }

      assert_equal :safe, result
    end

    test "Safely re-raises signals and exits so shutdown still works" do
      assert_raises(SystemExit) { Safely.call("test.exit") { exit(1) } }
      assert_raises(Interrupt) { Safely.call("test.interrupt") { raise Interrupt } }
    end

    test "Safely rate-limits repeated reports but counts every failure" do
      messages = []
      logger = Object.new
      logger.define_singleton_method(:error) { |message| messages << message }

      Observatory.config.logger = logger
      Observatory.config.error_report_interval = 3_600

      100.times { Safely.call("test.noisy") { raise "again" } }

      assert_equal 100, Safely.failure_counts["test.noisy"], "every failure is counted"
      assert_equal 1, messages.size, "but only one is logged"
    ensure
      Observatory.config.logger = nil
      Observatory.config.error_report_interval = 60.0
    end

    test "a failing subscriber cannot fail the request it is measuring" do
      execution = Execution::Request.new(trace_id: "a", request_id: nil, http_method: "GET", path: "/x")
      execution.define_singleton_method(:record_query) { |**| raise "instrumentation is broken" }

      Collectors::ActiveRecord.install!

      Current.with(execution) do
        # The application's work completes normally despite the subscriber
        # raising on every notification.
        assert_equal 1, ActiveRecord::Base.connection.select_value("SELECT 1")
      end

      assert_operator Safely.failure_counts["collectors.active_record.sql"], :>=, 1
    end
  end
end
