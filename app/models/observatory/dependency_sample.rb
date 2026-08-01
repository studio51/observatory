# frozen_string_literal: true

module Observatory

  # A periodic reading of one dependency: MySQL, Redis or a Sidekiq queue.
  #
  # `utilisation` is always *calculated* from measured counters, never inferred
  # from a latency figure. The difference matters: a Redis slowlog with seven
  # entries an hour says nothing about whether Redis is busy, whereas command CPU
  # time divided by uptime says exactly that. Reasoning from the former is how
  # "Redis is slow" gets written on an incident that had nothing to do with
  # Redis.
  #
  class DependencySample < Record
    self.table_name = "observatory_dependency_samples"

    MYSQL   = "mysql"
    REDIS   = "redis"
    SIDEKIQ = "sidekiq"

    scope :since, ->(time) { where(sampled_at: time..) }
    scope :between, ->(from, to) { where(sampled_at: from..to) }
    scope :for_dependency, ->(dependency) { where(dependency:) }
    scope :for_subject, ->(subject) { where(subject:) }
    scope :chronological, -> { order(:sampled_at) }
    scope :recent_first, -> { order(sampled_at: :desc) }

    scope :mysql, -> { for_dependency(MYSQL) }
    scope :redis, -> { for_dependency(REDIS) }
    scope :queues, -> { for_dependency(SIDEKIQ) }

    # The newest reading for a dependency.
    #
    # @param dependency [String] "mysql", "redis" or "sidekiq".
    # @param subject [String] the queue name or shard, where the dependency has one.
    #
    # @return [Observatory::DependencySample, nil]
    #
    def self.latest(dependency, subject: "")
      for_dependency(dependency).for_subject(subject).recent_first.first
    end

    # The newest reading for every Sidekiq queue.
    #
    # @param window [ActiveSupport::Duration] how far back a reading may be.
    #
    # @return [Array<Observatory::DependencySample>]
    #
    def self.latest_queues(window: 2.minutes)
      queues.since(window.ago).recent_first.group_by(&:subject).values.map(&:first)
    end

    # A measured metric from the reading.
    #
    # @param key [String, Symbol] the metric name.
    #
    # @return [Object, nil]
    #
    def metric(key)
      metrics.is_a?(Hash) ? metrics[key.to_s] : nil
    end

    # How long the queue would take to empty at its current completion rate.
    #
    # The number that turns a 536,542-job backlog from an alarm into an
    # observation: at 56.3 jobs a second it drains in two hours thirty-nine
    # minutes, and nothing is wrong.
    #
    # @return [String, nil] a human-readable duration, or nil when not draining.
    #
    def drain_estimate
      return nil if drain_seconds.nil? || drain_seconds.to_f <= 0
      return "not draining" if drain_seconds.to_f.infinite?

      ActiveSupport::Duration.build(drain_seconds.to_i).inspect
    end
  end
end
