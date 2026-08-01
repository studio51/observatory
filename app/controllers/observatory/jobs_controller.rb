# frozen_string_literal: true

module Observatory

  # Sidekiq: queues with their drain estimates, and the jobs consuming the most
  # worker capacity.
  #
  # Depth is never shown without throughput beside it. A queue of half a million
  # jobs draining at 56 a second is fine and a queue of five hundred that is not
  # draining is not, and only the pair distinguishes them.
  #
  class JobsController < ApplicationController
    PER_PAGE = 50

    # @return [void]
    #
    def index
      @queues     = DependencySample.latest_queues
      @overall    = DependencySample.latest(DependencySample::SIDEKIQ)
      @processes  = ProcessSample.latest_per_process(role: ProcessSample::SIDEKIQ)
      @by_class   = job_class_summary
      @slowest    = JobTrace.between(@from, @to).order(duration_ms: :desc).limit(15)
      @query_heavy = JobTrace.between(@from, @to).query_heavy.order(query_count: :desc).limit(15)
      @starved    = JobTrace.between(@from, @to).queue_starved.order(queue_latency_ms: :desc).limit(15)
    end

    # @return [void]
    #
    def show
      @trace  = JobTrace.find(params[:id])
      @groups = @trace.query_groups.most_repeated
      @incident = @trace.incident
    end

  private

    # Job classes ranked by the worker-seconds they consumed.
    #
    # @return [Array<Hash>]
    #
    def job_class_summary
      window.job_rollups.group_by(&:job_class).map do |job_class, rollups|
        count = rollups.sum(&:count)

        {
          job_class:,
          count:,
          failures:       rollups.sum(&:failure_count),
          retries:        rollups.sum(&:retry_count),
          worker_seconds: rollups.sum(&:worker_seconds),
          average_ms:     (count.positive? ? rollups.sum(&:duration_sum_ms) / count : 0.0),
          queue_latency_max_ms: rollups.map(&:queue_latency_max_ms).max.to_f,
          query_count:    rollups.sum(&:query_count_sum),
        }
      end.sort_by { |row| -row[:worker_seconds] }.first(25)
    end
  end
end
