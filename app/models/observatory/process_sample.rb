# frozen_string_literal: true

module Observatory

  # A periodic reading of one process: Puma capacity, memory, GC and pool state.
  #
  # ## Reading these honestly
  #
  # With `preload_app!` and three Puma workers there is no shared memory and no
  # control socket, so no process can see the cluster. Each worker samples
  # itself; the cluster view is assembled here by taking the newest sample per
  # process inside a window. That is an aggregate of independent readings, not a
  # synchronised snapshot, and {.capacity_now} reports how many processes
  # contributed so the dashboard can say so.
  #
  # A worker that stops reporting is shown as *stale*, never as zero — a
  # saturated worker that cannot schedule its sampler thread is itself a signal,
  # and treating its silence as "0 busy threads" would invert the finding.
  #
  class ProcessSample < Record
    self.table_name = "observatory_process_samples"

    WEB     = "web"
    SIDEKIQ = "sidekiq"

    scope :since, ->(time) { where(sampled_at: time..) }
    scope :between, ->(from, to) { where(sampled_at: from..to) }
    scope :web, -> { where(role: WEB) }
    scope :sidekiq, -> { where(role: SIDEKIQ) }
    scope :saturated, -> { where(saturated: true) }
    scope :chronological, -> { order(:sampled_at) }
    scope :recent_first, -> { order(sampled_at: :desc) }

    # The newest sample for each process within a window.
    #
    # @param window [ActiveSupport::Duration] how far back a sample may be and still count.
    # @param role [String] "web" or "sidekiq".
    #
    # @return [Array<Observatory::ProcessSample>]
    #
    def self.latest_per_process(window: 2.minutes, role: WEB)
      since(window.ago)
        .where(role:)
        .recent_first
        .group_by { |sample| [ sample.hostname, sample.process_id ] }
        .values
        .map(&:first)
    end

    # The cluster's current request capacity, assembled from per-worker samples.
    #
    # @param window [ActiveSupport::Duration] how far back a sample may be and still count.
    #
    # @return [Hash{Symbol => Object}] totals plus the provenance needed to read them.
    #
    def self.capacity_now(window: 2.minutes)
      samples = latest_per_process(window:, role: WEB)

      {
        workers_reporting: samples.size,
        max_threads:       samples.sum { |sample| sample.max_threads.to_i },
        busy_threads:      samples.sum { |sample| sample.busy_threads.to_i },
        idle_threads:      samples.sum { |sample| sample.idle_threads.to_i },
        # Summed only across workers that could measure it. nil everywhere means
        # unknown, and unknown is not zero.
        #
        backlog:           (samples.filter_map(&:backlog).sum if samples.any? { |s| !s.backlog.nil? }),
        saturated_workers: samples.count(&:saturated),
        rss_bytes:         samples.sum { |sample| sample.rss_bytes.to_i },
        sources:           samples.map(&:capacity_source).compact.uniq,
        sampled_at:        samples.map(&:sampled_at).max,
      }
    end

    # Share of this process's request threads that were busy.
    #
    # @return [Float] 0.0-1.0.
    #
    def thread_utilisation
      return 0.0 if max_threads.to_i.zero?

      busy_threads.to_f / max_threads
    end

    # Whether this reading came from Puma itself rather than a fallback.
    #
    # @return [Boolean]
    #
    def authoritative_capacity?
      capacity_source == "server"
    end
  end
end
