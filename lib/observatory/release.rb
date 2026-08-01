# frozen_string_literal: true

require "English"

module Observatory

  # Resolves the identifier of the code currently running.
  #
  # Every trace, sample and incident carries this, which is what makes "p95 on
  # this route went from 180 ms to 2.4 s" answerable with "…starting with the
  # deploy of `abc123`". Without it, a regression is a mystery; with it, it is a
  # diff.
  #
  # ## Where the identifier comes from in this application
  #
  # There is no `REVISION` file and no release environment variable. What exists
  # is `bin/dev`, which writes the SHA of the last fully successful deploy to
  # `tmp/pids/deploy.last-success` and rewrites it on every cutover. That file is
  # therefore the authoritative release marker on the production box, and this
  # resolver reads it — falling back, in order, to the conventional environment
  # variables and finally to the working tree's `git rev-parse` so development
  # and CI still produce something stable.
  #
  # The value is cached for the life of the process. A deploy replaces the
  # process, so a stale cache is not reachable; the cache is invalidated
  # explicitly only by the tests.
  #
  module Release
    ENVIRONMENT_KEYS = %w[
      OBSERVATORY_RELEASE
      GIT_SHA
      GIT_REVISION
      SOURCE_VERSION
      HEROKU_SLUG_COMMIT
      KAMAL_VERSION
      REVISION
    ].freeze

    UNKNOWN = "unknown".freeze
    SHORT_LENGTH = 12

    class << self

      # The active release identifier.
      #
      # @return [String] a short SHA, a configured identifier, or "unknown".
      #
      def current
        @current ||= Safely.call("release.resolve", fallback: UNKNOWN) { resolve }
      end

      # Everything known about the running release, for a deployment marker.
      #
      # @return [Hash{Symbol => Object}]
      #
      def details
        {
          release:        current,
          branch:         Safely.call("release.branch") { git("rev-parse --abbrev-ref HEAD") },
          schema_version: Safely.call("release.schema") { schema_version },
          booted_at:      Observatory.booted_at,
          ruby_version:   RUBY_VERSION,
          rails_version:  (Rails::VERSION::STRING if defined?(Rails::VERSION)),
          environment:    (Rails.env.to_s if defined?(Rails)),
        }
      end

      # Forget the cached identifier. Test-suite hygiene only.
      #
      # @return [void]
      #
      def reset!
        @current = nil

        nil
      end

    private

      # Work through the resolution chain, first hit wins.
      #
      # @return [String]
      #
      def resolve
        from_configured_resolver ||
          from_environment ||
          from_deploy_marker ||
          from_git ||
          UNKNOWN
      end

      # A host-supplied callable, which always wins — an application that knows
      # its own release identity should not be second-guessed.
      #
      # @return [String, nil]
      #
      def from_configured_resolver
        resolver = Observatory.config.release_resolver
        return nil if resolver.nil?

        value = resolver.call

        presence(value)
      end

      # @return [String, nil]
      #
      def from_environment
        ENVIRONMENT_KEYS.each do |key|
          value = presence(ENV[key])

          return shorten(value) if value
        end

        nil
      end

      # The SHA `bin/dev` recorded after its last successful deploy.
      #
      # @return [String, nil]
      #
      def from_deploy_marker
        path = Observatory.config.deployment_marker_path
        return nil if path.nil?

        absolute = Pathname.new(path).absolute? ? path : File.join(Observatory.root_path.to_s, path)
        return nil unless File.readable?(absolute)

        shorten(presence(File.read(absolute)))
      end

      # @return [String, nil]
      #
      def from_git
        shorten(presence(git("rev-parse HEAD")))
      end

      # Run a git command in the application root, returning nil on any failure.
      #
      # Guarded by a whitelist of arguments because this shells out; the argument
      # is never user-supplied, and keeping it that way is the point of the guard.
      #
      # @param arguments [String] the git arguments to run.
      #
      # @return [String, nil] trimmed output, or nil when git failed or is absent.
      #
      def git(arguments)
        return nil unless %w[rev-parse].include?(arguments.split.first)

        output = IO.popen([ "git", "-C", Observatory.root_path.to_s, *arguments.split ], err: File::NULL, &:read)

        $CHILD_STATUS&.success? ? presence(output) : nil
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      # The application's current migration version, so a deployment marker can
      # record whether the schema moved.
      #
      # @return [String, nil]
      #
      def schema_version
        return nil unless defined?(ActiveRecord::Base)

        Instrumentation.suppress do
          ActiveRecord::Base.connection_pool.migration_context.current_version.to_s
        end
      end

      # @param value [String, nil] a candidate identifier.
      #
      # @return [String, nil] the value stripped, or nil when blank.
      #
      def presence(value)
        stripped = value.to_s.strip

        stripped.empty? ? nil : stripped
      end

      # @param value [String, nil] a SHA or identifier.
      #
      # @return [String, nil] shortened to {SHORT_LENGTH} when it looks like a SHA.
      #
      def shorten(value)
        return nil if value.nil?
        return value unless value.match?(/\A[0-9a-f]{40}\z/i)

        value[0, SHORT_LENGTH]
      end
    end
  end
end
