# frozen_string_literal: true

module Observatory

  # One deployment, so a regression can be attributed to a release.
  #
  # In this application there is no release environment variable and no REVISION
  # file — `bin/dev` writes the SHA of the last successful deploy to
  # `tmp/pids/deploy.last-success` on every cutover, and that file is the marker.
  # {Observatory::Release} reads it; this records the transitions.
  #
  # Correlation is not causation and this model does not pretend otherwise: it
  # records *when* a release started running, and the analysis engine reports a
  # before-and-after comparison with an explicit confidence rather than a verdict.
  #
  class Deployment < Record
    self.table_name = "observatory_deployments"

    scope :recent_first, -> { order(deployed_at: :desc) }
    scope :since, ->(time) { where(deployed_at: time..) }

    # Record the running release if it has not been seen before.
    #
    # Idempotent, and called on every boot: three Puma workers and two Sidekiq
    # processes coming up on the same release must produce one row, not five.
    #
    # @param details [Hash] a {Observatory::Release.details} hash.
    #
    # @return [Observatory::Deployment, nil]
    #
    def self.record!(details = Release.details)
      release = details[:release].to_s
      return nil if release.empty? || release == Release::UNKNOWN

      Instrumentation.suppress do
        create_with(
          deployed_at:    Clock.wall,
          branch:         details[:branch],
          schema_version: details[:schema_version],
          hostname:       Observatory.hostname,
          ruby_version:   details[:ruby_version],
          rails_version:  details[:rails_version],
          environment:    details[:environment],
          details:        details.except(:release),
        ).find_or_create_by(release:)
      end
    rescue ActiveRecord::RecordNotUnique
      find_by(release:)
    end

    # The deployment that was running at a given moment.
    #
    # @param time [Time] the moment to resolve.
    #
    # @return [Observatory::Deployment, nil]
    #
    def self.at(time)
      where(deployed_at: ..time).recent_first.first
    end

    # The deployment before this one.
    #
    # @return [Observatory::Deployment, nil]
    #
    def previous
      self.class.where(deployed_at: ...deployed_at).recent_first.first
    end

    # When this release stopped being the running one.
    #
    # @return [Time, nil] nil while it is still current.
    #
    def superseded_at
      self.class.where(deployed_at: (deployed_at + 1.second)..).order(:deployed_at).first&.deployed_at
    end

    # A short label for timelines.
    #
    # @return [String]
    #
    def label
      "#{release}#{" (#{branch})" if branch.present?}"
    end
  end
end
