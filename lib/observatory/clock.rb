# frozen_string_literal: true

module Observatory

  # Time and resource-counter readings, in one place.
  #
  # Durations are always measured with `CLOCK_MONOTONIC` — a wall clock can step
  # backwards over an NTP correction and produce a negative request duration,
  # which would then be indistinguishable from a bug in the instrumentation.
  # Wall-clock times are recorded separately, purely so a trace can be placed on
  # a timeline.
  #
  module Clock
    module_function

    # Monotonic seconds, for measuring elapsed time.
    #
    # @return [Float]
    #
    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Milliseconds elapsed since a monotonic reading.
    #
    # @param since [Float] an earlier {monotonic} value.
    #
    # @return [Float] milliseconds, never negative.
    #
    def elapsed_ms(since)
      (monotonic - since) * 1_000.0
    end

    # Wall-clock time, for placing a trace on a timeline.
    #
    # @return [Time] UTC.
    #
    def wall
      Time.now.utc
    end

    # CPU seconds consumed by this process, user plus system.
    #
    # Sampled at process level only — Ruby exposes no per-thread CPU clock
    # portably, so this is never attributed to an individual request.
    #
    # @return [Float] seconds.
    #
    def process_cpu
      Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    end
  end

  # A reading of the process-wide allocation and garbage-collection counters.
  #
  # ## These numbers are estimates, and the naming says so
  #
  # CRuby has no per-thread allocation counter (`Thread#allocated_object_count`
  # is a JRuby/TruffleRuby API — verified absent on the Ruby 4.0.5 this
  # application runs). Every counter here is process-wide, and a Puma worker
  # serves up to five requests concurrently, so a delta taken around one request
  # includes whatever the other four threads allocated in the same window.
  #
  # Observatory therefore never claims exact per-request allocation or GC time.
  # The fields are named `allocation_delta` and `estimated_gc_time_ms`, the
  # dashboard labels them as estimates, and the detection rules that use them
  # require a large multiple over baseline rather than a marginal one — because
  # a marginal difference here is indistinguishable from a noisy neighbour.
  #
  # What the numbers *are* good for: spotting the request that allocated eighty
  # million objects, which no amount of concurrent contamination can manufacture.
  #
  GcSnapshot = Struct.new(:allocated_objects, :freed_objects, :gc_count, :major_gc_count, :gc_time_ns) do
    # Read the current process-wide counters.
    #
    # `GC.stat(:key)` is used rather than `GC.stat` because the latter allocates
    # a thirty-key hash on every call, which on the request path would be
    # instrumentation measuring its own overhead.
    #
    # @return [Observatory::GcSnapshot]
    #
    def self.capture
      new(
        GC.stat(:total_allocated_objects),
        GC.stat(:total_freed_objects),
        GC.count,
        GC.stat(:major_gc_count),
        GC.respond_to?(:total_time) ? GC.total_time : 0,
      )
    end

    # The difference between this snapshot and an earlier one.
    #
    # @param earlier [Observatory::GcSnapshot] the reading taken at the start.
    #
    # @return [Hash{Symbol => Numeric}] deltas, with GC time converted to milliseconds.
    #
    def delta_from(earlier)
      {
        allocation_delta:      allocated_objects - earlier.allocated_objects,
        freed_delta:           freed_objects - earlier.freed_objects,
        gc_runs:               gc_count - earlier.gc_count,
        major_gc_runs:         major_gc_count - earlier.major_gc_count,
        estimated_gc_time_ms:  ((gc_time_ns - earlier.gc_time_ns) / 1_000_000.0).round(3),
      }
    end
  end
end
