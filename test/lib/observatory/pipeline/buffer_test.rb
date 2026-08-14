# frozen_string_literal: true

require "test_helper"

module Observatory
  module Pipeline

    # The buffer's contract is the promise that Observatory cannot become the
    # outage: bounded memory, never blocking the pusher, and — when it must lose
    # data — losing the *least useful* data rather than whatever happened to
    # arrive last.
    #
    class BufferTest < ActiveSupport::TestCase

      test "accepts events up to capacity" do
        buffer = Buffer.new(capacity: 3)

        3.times { |index| assert buffer.push({ index: }) }

        assert_equal 3, buffer.size
      end

      test "drops a normal event at capacity rather than growing" do
        buffer = Buffer.new(capacity: 2)
        2.times { |index| buffer.push({ index: }) }

        assert_not buffer.push({ index: 99 })
        assert_equal 2, buffer.size, "capacity is a hard ceiling"
        assert_equal 1, buffer.stats[:dropped]
      end

      test "never blocks the pusher even when saturated" do
        buffer = Buffer.new(capacity: 1)
        buffer.push({ first: true })

        # A SizedQueue would block here, holding a Puma thread. This must not.
        completed = Timeout.timeout(2) do
          10_000.times { buffer.push({ noise: true }) }

          true
        end

        assert completed
      end

      test "a critical event evicts a normal one to make room" do
        buffer = Buffer.new(capacity: 2)
        buffer.push({ kind: :normal_one }, priority: :normal)
        buffer.push({ kind: :normal_two }, priority: :normal)

        assert buffer.push({ kind: :incident }, priority: :critical)

        kinds = buffer.pop_batch(limit: 10, timeout: 0).map { |payload| payload[:kind] }

        assert_includes kinds, :incident, "the incident event survives"
        assert_includes kinds, :normal_two
        assert_not_includes kinds, :normal_one, "the oldest low-value event is what was evicted"
      end

      test "a high-priority event evicts a normal one but not a critical one" do
        buffer = Buffer.new(capacity: 2)
        buffer.push({ kind: :critical }, priority: :critical)
        buffer.push({ kind: :normal }, priority: :normal)

        assert buffer.push({ kind: :anomaly }, priority: :high)

        kinds = buffer.pop_batch(limit: 10, timeout: 0).map { |payload| payload[:kind] }

        assert_includes kinds, :critical
        assert_includes kinds, :anomaly
        assert_not_includes kinds, :normal
      end

      test "drops a critical event only when everything buffered is also critical" do
        buffer = Buffer.new(capacity: 2)
        2.times { buffer.push({ kind: :critical }, priority: :critical) }

        assert_not buffer.push({ kind: :one_too_many }, priority: :critical)
        assert_equal 2, buffer.size
      end

      test "counts every drop so a degraded pipeline is visible rather than silent" do
        buffer = Buffer.new(capacity: 1)
        buffer.push({ a: 1 })
        5.times { buffer.push({ b: 2 }) }
        buffer.push({ c: 3 }, priority: :critical)

        stats = buffer.stats

        assert_equal 6, stats[:dropped], "5 refused normals plus the 1 evicted for the critical"
        assert_equal 1, stats[:evicted]
        assert_equal 1, stats[:capacity]
      end

      test "pops in arrival order" do
        buffer = Buffer.new(capacity: 10)
        3.times { |index| buffer.push({ index: }) }

        assert_equal [ 0, 1, 2 ], buffer.pop_batch(limit: 10, timeout: 0).map { |payload| payload[:index] }
      end

      test "pops at most the requested batch size" do
        buffer = Buffer.new(capacity: 10)
        10.times { |index| buffer.push({ index: }) }

        assert_equal 4, buffer.pop_batch(limit: 4, timeout: 0).size
        assert_equal 6, buffer.size
      end

      test "waits rather than spinning when empty" do
        buffer = Buffer.new(capacity: 10)
        started = Observatory::Clock.monotonic

        assert_empty buffer.pop_batch(limit: 10, timeout: 0.1)
        assert_operator Observatory::Clock.monotonic - started, :>=, 0.09
      end

      test "is safe under concurrent producers" do
        buffer = Buffer.new(capacity: 10_000)

        threads = 8.times.map do |worker|
          Thread.new { 500.times { |index| buffer.push({ worker:, index: }) } }
        end
        threads.each(&:join)

        assert_equal 4_000, buffer.size
        assert_equal 4_000, buffer.stats[:accepted]
      end
    end
  end
end
