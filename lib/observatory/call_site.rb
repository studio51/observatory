# frozen_string_literal: true

module Observatory

  # Finds the application frame responsible for a repeatedly-executed query.
  #
  # "86,359 lookups, 97% cached" tells an operator *what* is wrong. This tells
  # them *where*: the one line of application code sitting inside the loop.
  # Without it the finding is a puzzle; with it it is a diff.
  #
  # ## Why this is fenced so carefully
  #
  # `caller_locations` walks the stack and allocates a Location per frame. Called
  # from the SQL subscriber it would run once per query — 86,359 times on the
  # request that matters most — and the instrumentation would become a larger
  # problem than the bug it found.
  #
  # So it never runs per query. It runs at most `max_call_sites` times per
  # execution (default 3), and only after a single fingerprint has already
  # repeated `query_call_site_threshold` times (default 100). By then the shape
  # is proven pathological and three stack walks are free by comparison. The
  # whole mechanism can be switched off with `capture_query_call_sites = false`.
  #
  # The measured cost of one capture is in
  # `test/performance/call_site_benchmark_test.rb`.
  #
  module CallSite

    # Frames to skip before starting the search: this module, the execution
    # context that called it, and the subscriber that called that.
    #
    START_DEPTH = 4

    class << self

      # The nearest application frame above the instrumentation.
      #
      # Walks a bounded window of the stack, skipping anything that looks like
      # framework, gem, standard-library or Observatory code, and returns the
      # first frame that is left — which is, by construction, application code.
      #
      # @param config [Observatory::Configuration] supplies the depth and ignore list.
      #
      # @return [String, nil] "app/models/thing.rb:42:in `each'", or nil when
      #   every frame in the window was framework code.
      #
      def find(config = Observatory.config)
        frames = caller_locations(START_DEPTH, config.call_site_depth)
        return nil if frames.nil?

        ignores = config.call_site_ignore_patterns

        frames.each do |frame|
          path = frame.absolute_path || frame.path
          next if path.nil?
          next if ignored?(path, ignores)

          return format_location(path, frame)
        end

        nil
      end

    private

      # @param path [String] the frame's file path.
      # @param ignores [Array<String>] path fragments marking non-application code.
      #
      # @return [Boolean] whether the frame should be skipped.
      #
      def ignored?(path, ignores)
        ignores.any? { |fragment| path.include?(fragment) }
      end

      # Render a frame relative to the application root, so a stored call site is
      # stable across deploys and readable in the dashboard.
      #
      # @param path [String] absolute path to the frame's file.
      # @param frame [Thread::Backtrace::Location] the frame itself.
      #
      # @return [String]
      #
      def format_location(path, frame)
        root = Observatory.root_path
        relative = root && path.start_with?(root) ? path[root.length + 1..] : path

        "#{relative}:#{frame.lineno}:in `#{frame.label}'"
      end
    end
  end
end
