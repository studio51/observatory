# frozen_string_literal: true

module Observatory
  module Probes

    # Reads Sidekiq's queues, processes and throughput.
    #
    # ## Queue depth on its own is not a signal
    #
    # A queue with 536,542 jobs in it looks like an emergency and usually is not.
    # The number that decides is **throughput**, and the number an operator
    # actually wants is the one derived from both:
    #
    #   estimated drain time = queue depth / completion rate
    #
    #   Queue: default
    #   Depth: 536,542          Throughput: 56.3 jobs/second
    #   Drain: 2 hours 39 minutes
    #   Failure rate: normal    Retries: normal    Constraint: none detected
    #
    # That is a queue doing its job. The same depth with a falling completion
    # rate and a rising drain estimate is a queue that will never empty — a
    # completely different situation, indistinguishable from the first if all you
    # plot is depth.
    #
    # ## Cumulative counters are labelled as such
    #
    # `Sidekiq::Stats#processed` counts since the Redis database was created, not
    # since anything meaningful. Presented as a live gauge it is nonsense.
    # Throughput here is derived from the *difference* between consecutive
    # readings, which is why the probe keeps the previous one.
    #
    module Sidekiq
      class << self

        # A measured snapshot of Sidekiq: queues, processes and throughput.
        #
        # @return [Hash{Symbol => Object}, nil] nil when Sidekiq is unavailable.
        #
        def sample
          return nil unless available?

          Safely.call("probes.sidekiq.sample") do
            Instrumentation.suppress do
              stats = ::Sidekiq::Stats.new
              throughput = throughput_since_last_sample(stats.processed)

              {
                queues:        queue_samples(throughput),
                processes:     process_samples,
                enqueued:      stats.enqueued,
                scheduled:     stats.scheduled_size,
                retries:       stats.retry_size,
                dead:          stats.dead_size,
                busy_workers:  stats.workers_size,
                throughput:    throughput,
                # Cumulative since the Redis database was created. Historical,
                # not a rate — the dashboard renders these differently for that
                # reason.
                #
                processed_total: stats.processed,
                failed_total:    stats.failed,
              }
            end
          end
        end

        # Whether Sidekiq's API is usable in this process.
        #
        # @return [Boolean]
        #
        def available?
          defined?(::Sidekiq::Stats) && defined?(::Sidekiq::Queue)
        end

        # Forget the previous reading. Test-suite hygiene only.
        #
        # @return [void]
        #
        def reset!
          @last_processed = nil
          @last_sampled_at = nil

          nil
        end

      private

        # Per-queue depth, latency and drain estimate.
        #
        # @param total_throughput [Float, nil] jobs completed per second across all queues.
        #
        # @return [Array<Hash{Symbol => Object}>]
        #
        def queue_samples(total_throughput)
          queues = ::Sidekiq::Queue.all
          total_depth = queues.sum(&:size)

          queues.map do |queue|
            depth = queue.size
            # Throughput is only measurable in aggregate, so it is apportioned by
            # each queue's share of the backlog. An approximation, and the
            # dashboard says so rather than implying a per-queue measurement.
            #
            share = total_depth.positive? ? (depth.to_f / total_depth) : 0.0
            rate = total_throughput.to_f * share

            {
              name:          queue.name,
              depth:         depth,
              latency:       queue.latency,
              paused:        queue.respond_to?(:paused?) && queue.paused?,
              throughput:    rate.round(3),
              drain_seconds: drain_seconds(depth, rate),
            }
          end
        end

        # How long a queue would take to empty at its current completion rate.
        #
        # @param depth [Integer] jobs waiting.
        # @param rate [Float] jobs completed per second.
        #
        # @return [Float, nil] seconds; Infinity when nothing is draining it.
        #
        def drain_seconds(depth, rate)
          return 0.0 if depth.zero?
          return Float::INFINITY if rate <= 0

          (depth / rate).round(1)
        end

        # The running Sidekiq processes and how loaded each one is.
        #
        # @return [Array<Hash{Symbol => Object}>]
        #
        def process_samples
          ::Sidekiq::ProcessSet.new.map do |process|
            concurrency = process["concurrency"].to_i
            busy = process["busy"].to_i

            {
              identity:    process["identity"],
              hostname:    process["hostname"],
              pid:         process["pid"],
              concurrency: concurrency,
              busy:        busy,
              utilisation: (concurrency.positive? ? (busy.to_f / concurrency).round(4) : nil),
              queues:      process["queues"],
              rss_kb:      process["rss"],
              started_at:  (Time.at(process["started_at"]).utc if process["started_at"]),
              quiet:       process["quiet"] == "true",
            }
          end
        rescue StandardError
          []
        end

        # Jobs completed per second since the previous reading.
        #
        # Nil on the first reading of a process's life — there is nothing to
        # difference against yet, and reporting the cumulative counter divided by
        # uptime would be a lifetime average masquerading as a current rate.
        #
        # @param processed [Integer] Sidekiq's cumulative processed counter.
        #
        # @return [Float, nil] jobs per second.
        #
        def throughput_since_last_sample(processed)
          now = Clock.monotonic
          previous_count = @last_processed
          previous_at = @last_sampled_at

          @last_processed = processed
          @last_sampled_at = now

          return nil if previous_count.nil? || previous_at.nil?

          elapsed = now - previous_at
          return nil if elapsed <= 0

          delta = processed - previous_count
          return 0.0 if delta.negative?   # Redis was flushed, or the counter reset

          (delta / elapsed).round(3)
        end
      end
    end
  end
end
