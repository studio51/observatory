# frozen_string_literal: true

module Observatory

  # The fail-open boundary.
  #
  # A monitoring system that turns a working request into a 500 is worse than no
  # monitoring system. Every entry point Observatory owns — subscribers,
  # middleware, probes, the writer — runs its work inside {Safely.call}, which
  # swallows *everything* (including `StandardError` subclasses the application
  # would otherwise handle) and reports it out of band.
  #
  # Reports are rate-limited per call site so a subscriber failing on every one
  # of 86,000 queries produces one log line a minute, not 86,000. The internal
  # failure counters are exposed on the dashboard, because silent monitoring is
  # its own kind of outage.
  #
  # `Exception` rather than `StandardError` is caught deliberately: a
  # `NoMethodError` inside a probe adapter after a gem upgrade is exactly the
  # class of failure that must not reach the application, and re-raising
  # `SignalException`/`SystemExit` keeps shutdown working.
  #
  module Safely
    PASS_THROUGH = [ SystemExit, SignalException, Interrupt, NoMemoryError, SystemStackError ].freeze

    @failures = Hash.new(0)   # call-site label => total failures observed
    @last_report = {}         # call-site label => monotonic time of the last log line
    @mutex = Mutex.new

    class << self
      attr_reader :failures

      # Run the block, absorbing any failure.
      #
      # @param label [String, Symbol] identifies the call site in logs and counters.
      # @param fallback [Object] returned when the block raises.
      #
      # @yield the instrumentation work to attempt.
      #
      # @return [Object] the block's value, or `fallback` when it raised.
      #
      def call(label, fallback: nil)
        yield
      rescue *PASS_THROUGH
        raise
      rescue Exception => exception # rubocop:disable Lint/RescueException
        record(label, exception)

        fallback
      end

      # Total internal failures recorded since boot, by call site.
      #
      # Rendered on the dashboard's diagnostics panel — a rising count here means
      # Observatory is degraded and its numbers should be trusted less.
      #
      # @return [Hash{String => Integer}] a snapshot, safe to iterate.
      #
      def failure_counts
        @mutex.synchronize { @failures.dup }
      end

      # Forget every recorded failure. Test-suite hygiene only.
      #
      # @return [void]
      #
      def reset!
        @mutex.synchronize do
          @failures.clear
          @last_report.clear
        end

        nil
      end

    private

      # Count the failure and, at most once per configured interval per label,
      # write it to Observatory's own log and hand it to the host's error
      # reporter.
      #
      # @param label [String, Symbol] the failing call site.
      # @param exception [Exception] what went wrong.
      #
      # @return [void]
      #
      def record(label, exception)
        key = label.to_s
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        report = false

        @mutex.synchronize do
          @failures[key] += 1
          interval = Observatory.config.error_report_interval

          if @last_report[key].nil? || (now - @last_report[key]) >= interval
            @last_report[key] = now
            report = true
          end
        end

        return unless report

        Observatory.logger.error(
          "[observatory] #{key} failed (#{@failures[key]}x): " \
          "#{exception.class}: #{exception.message}\n" \
          "#{Array(exception.backtrace).first(5).join("\n")}",
        )

        # The host may or may not have an error reporter wired up; a failure to
        # report a failure must not itself raise.
        #
        Rails.error.report(exception, handled: true, source: "observatory") if defined?(Rails.error)
      rescue Exception # rubocop:disable Lint/RescueException, Lint/SuppressedException
        # Reporting is best-effort by definition. Nothing left to do.
        #
      end
    end
  end
end
