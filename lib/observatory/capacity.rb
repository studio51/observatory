# frozen_string_literal: true

module Observatory

  # The process's live register of in-flight requests.
  #
  # This exists because of a specific gap. Puma knows how many of its threads are
  # busy, but inside a forked cluster worker `Puma.stats_hash` returns the
  # master's stale view (see the architecture note), and this application runs no
  # Puma control socket. Observatory therefore keeps its own count — which has
  # the useful property of being exactly right about the thing that matters: how
  # many requests are *inside the Rack application* right now, and which ones.
  #
  # Two questions it answers that nothing else can:
  #
  # - **"Was the process saturated when `/up` timed out?"** If five of five
  #   request threads were occupied by fourteen-second requests, the process was
  #   alive and full, not dead — and the watchdog restarted it for the wrong
  #   reason.
  # - **"What was running at the time?"** The register holds the live executions,
  #   so a saturation incident can name the six concurrent requests that caused
  #   it instead of merely counting them.
  #
  # Everything here is guarded by one mutex and is O(1) per request. The registry
  # is bounded by the thread count — a process cannot have more in-flight
  # requests than it has threads — so it needs no eviction policy.
  #
  module Capacity
    @mutex     = Mutex.new
    @in_flight = {}   # thread object_id => Execution::Request
    @peak      = 0    # highest concurrent count since the last reset
    @saturated_since = nil # monotonic time at which every thread became busy

    class << self

      # Register a request as occupying a thread.
      #
      # @param execution [Observatory::Execution::Request] the starting request.
      #
      # @return [Integer] in-flight requests including this one.
      #
      def enter(execution)
        @mutex.synchronize do
          @in_flight[execution.thread_id] = execution
          count = @in_flight.size
          @peak = count if count > @peak

          track_saturation(count)

          count
        end
      end

      # Release a request's thread.
      #
      # @param execution [Observatory::Execution::Request] the finishing request.
      #
      # @return [Integer] in-flight requests after this one left.
      #
      def leave(execution)
        @mutex.synchronize do
          @in_flight.delete(execution.thread_id)
          count = @in_flight.size

          track_saturation(count)

          count
        end
      end

      # How many requests are inside the Rack application right now.
      #
      # @return [Integer]
      #
      def in_flight_count
        @mutex.synchronize { @in_flight.size }
      end

      # The requests currently in flight, newest first.
      #
      # Used by the saturation incident and by the watchdog's pre-restart evidence
      # capture, which is the moment it matters most: "these six requests, each
      # over ten seconds old, are holding every thread you have".
      #
      # @return [Array<Observatory::Execution::Request>] a snapshot, safe to iterate.
      #
      def in_flight
        @mutex.synchronize { @in_flight.values }
      end

      # Requests that have been running longer than the given threshold.
      #
      # @param seconds [Float] age in seconds.
      #
      # @return [Array<Observatory::Execution::Request>] longest-running first.
      #
      def long_running(seconds)
        now = Clock.monotonic

        in_flight
          .select { |execution| (now - execution.started_monotonic) >= seconds }
          .sort_by { |execution| execution.started_monotonic }
      end

      # How long every request thread in this process has been occupied.
      #
      # Nil when the process is not currently saturated. A non-nil value that
      # keeps growing past `puma_saturation_duration` is the trigger for the
      # thread-saturation rule.
      #
      # @return [Float, nil] seconds.
      #
      def saturated_for
        started = @saturated_since
        return nil if started.nil?

        Clock.monotonic - started
      end

      # Highest concurrent request count seen since the last {reset_peak!}.
      #
      # @return [Integer]
      #
      def peak
        @mutex.synchronize { @peak }
      end

      # Read and clear the peak watermark.
      #
      # Called by the sampler once per interval, so each sample reports the peak
      # *within* that interval rather than since boot.
      #
      # @return [Integer] the peak that was cleared.
      #
      def reset_peak!
        @mutex.synchronize do
          peak = @peak
          @peak = @in_flight.size

          peak
        end
      end

      # The configured number of request threads this process can run.
      #
      # Read from Puma's own configuration when Puma is present, falling back to
      # `RAILS_MAX_THREADS`. This is the denominator of every capacity figure, so
      # it is resolved once and cached.
      #
      # @return [Integer]
      #
      def max_threads
        @max_threads ||= Observatory::Probes::Puma.configured_max_threads
      end

      # Forget all state. Test-suite hygiene only.
      #
      # @return [void]
      #
      def reset!
        @mutex.synchronize do
          @in_flight.clear
          @peak = 0
          @saturated_since = nil
          @max_threads = nil
        end

        nil
      end

    private

      # Start or stop the saturation stopwatch as the in-flight count crosses the
      # thread ceiling.
      #
      # Called with the mutex already held.
      #
      # @param count [Integer] current in-flight requests.
      #
      # @return [void]
      #
      def track_saturation(count)
        if count >= max_threads
          @saturated_since ||= Clock.monotonic
        else
          @saturated_since = nil
        end

        nil
      end
    end
  end
end
