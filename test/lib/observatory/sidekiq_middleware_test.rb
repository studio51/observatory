# frozen_string_literal: true

require "test_helper"

module Observatory
  module Sidekiq

    # A job that performs 86,000 lookups is the same bug as a request that does,
    # and it must read the same way. These tests check that the job path collects
    # what the request path collects, plus the two measurements only queued work
    # has.
    #
    class MiddlewareTest < ActiveSupport::TestCase

      setup do
        @middleware = Middleware::Server.new
      end

      test "measures a job's queries and duration" do
        payloads = capture_observatory_payloads do
          run_job do
            10.times { |index| record_query("SELECT * FROM games WHERE id = #{index}", cached: index.odd?) }
          end
        end

        trace = payloads.first

        assert_equal "job", trace[:event]
        assert_equal "HardWorker", trace[:job_class]
        assert_equal "default", trace[:queue]
        assert_equal 10, trace[:query_count]
        assert_equal 5, trace[:cached_query_count]
        assert_equal "success", trace[:result]
      end

      test "records queue latency, which is what separates a deep queue from a stuck one" do
        payloads = capture_observatory_payloads do
          run_job(enqueued_at: 90.seconds.ago.to_f) { nil }
        end

        latency = payloads.first[:queue_latency_ms]

        assert_operator latency, :>=, 89_000
        assert_operator latency, :<=, 95_000
      end

      test "records a failure and lets the exception through to Sidekiq" do
        payloads = capture_observatory_payloads do
          assert_raises(RuntimeError) { run_job { raise "job blew up" } }
        end

        trace = payloads.first

        assert_equal "failure", trace[:result]
        assert_equal "RuntimeError", trace[:exception_class]
      end

      test "reports the wrapped class rather than ActiveJob's wrapper" do
        job = job_payload.merge("class" => "Sidekiq::JobWrapper", "wrapped" => "Steam::SyncJob")

        assert_equal "Steam::SyncJob", Middleware.job_class_for(job)
      end

      test "carries the enqueueing request's trace id into the job" do
        request = Execution::Request.new(
          trace_id: "parent-trace", request_id: nil, http_method: "GET", path: "/x",
        )
        job = job_payload

        with_observatory do
          Current.with(request) do
            Middleware::Client.new.call("HardWorker", job, "default", nil) { nil }
          end
        end

        assert_equal "parent-trace", job[Middleware::TRACE_KEY]
        assert job[Middleware::ENQUEUED_AT].present?
      end

      test "never instruments Observatory's own jobs" do
        assert Middleware.internal?("class" => "Observatory::SweepJob")
        assert_not Middleware.internal?("class" => "HardWorker")
      end

      test "recognises an Observatory job ActiveJob wrapped" do
        job = job_payload.merge("class" => "Sidekiq::JobWrapper", "args" => [ { "job_class" => "Observatory::SweepJob" } ])

        assert Middleware.internal?(job)
      end

      # A plain Sidekiq worker's first argument is whatever the caller passed —
      # an id, a GlobalID, an array. Every one of those used to be read as an
      # ActiveJob payload, and the resulting TypeError was raised *before* the
      # job ran, killing it. Nothing caught it because every payload in this file
      # was built with no arguments at all.
      #
      [ 179, "gid://my-games-io/XBOX::Game/2", [ "gid://my-games-io/XBOX::Game/2", "review" ], nil ].each do |first|
        test "a plain worker's #{ first.class } argument is not mistaken for an ActiveJob payload" do
          job = job_payload.merge("args" => [ first, "review" ])

          assert_not Middleware.internal?(job)
          assert_equal "HardWorker", Middleware.job_class_for(job)
        end
      end

      test "a plain worker with arguments still runs and is still measured" do
        payloads = capture_observatory_payloads do
          @middleware.call(nil, job_payload.merge("args" => [ 179 ]), "default") { nil }
        end

        assert_equal "HardWorker", payloads.first[:job_class]
      end

      test "an Observatory job produces no trace at all" do
        payloads = capture_observatory_payloads do
          @middleware.call(nil, job_payload.merge("class" => "Observatory::SweepJob"), "default") { nil }
        end

        assert_empty payloads
      end

      test "a job runs normally when Observatory is disabled" do
        ran = false

        capture_observatory_payloads(enabled: false) do
          @middleware.call(nil, job_payload, "default") { ran = true }
        end

        assert ran
      end

    private

      # @param enqueued_at [Float] when the job was pushed, as a unix timestamp.
      #
      # @yield the job body.
      #
      # @return [Object] whatever the job body returns.
      #
      def run_job(enqueued_at: Time.current.to_f, &block)
        @middleware.call(nil, job_payload(enqueued_at:), "default", &block)
      end

      # @param enqueued_at [Float] when the job was pushed.
      #
      # @return [Hash] a Sidekiq job payload.
      #
      def job_payload(enqueued_at: Time.current.to_f)
        {
          "class" => "HardWorker", "jid" => SecureRandom.hex(12), "queue" => "default",
          "args" => [], "retry_count" => 0, "enqueued_at" => enqueued_at,
        }
      end

      # @param sql [String] the statement.
      # @param cached [Boolean] whether the query cache served it.
      #
      # @return [void]
      #
      def record_query(sql, cached:)
        Current.execution&.record_query(sql:, name: "Load", duration_ms: 0.2, cached:)

        nil
      end
    end
  end
end
