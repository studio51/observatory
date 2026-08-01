# frozen_string_literal: true

module Observatory
  module Execution

    # One HTTP request, from Rack entry to response.
    #
    # Identity is deliberately route-shaped rather than URL-shaped: the trace
    # records `/steam/achievements/:id`, not `/steam/achievements/839292`. A
    # literal URL cannot be grouped, cannot be compared against a baseline, and
    # carries whatever identifiers happen to be in the path. The template can do
    # all three and carries none.
    #
    class Request < Base
      attr_reader :request_id       # Rails' X-Request-Id, shared with the application log
      attr_reader :http_method      # GET, POST, …
      attr_reader :route            # Rails route template, once the router has resolved it
      attr_reader :controller       # controller class name
      attr_reader :action           # action name
      attr_reader :status           # response status
      attr_reader :response_bytes   # Content-Length, where the response declares one
      attr_reader :user_agent       # raw user agent, kept for classification then discarded
      attr_reader :client_id        # HMAC of the client address; never the address itself
      attr_reader :traffic_class    # :human, :search_crawler, :health_check, …
      attr_reader :queue_wait_ms    # time between the proxy accepting and Rack starting; nil when unknown
      attr_reader :health_check     # whether this request is a health probe
      attr_reader :concurrent_at_start # in-flight requests in this process when this one began
      attr_reader :peak_concurrency # highest in-flight count observed during this request
      attr_reader :pool_stat        # ActiveRecord pool gauge sampled at completion

      # @param trace_id [String] correlation id.
      # @param request_id [String, nil] Rails' request id, when the host sets one.
      # @param http_method [String] the HTTP verb.
      # @param path [String] the request path, used only for classification and never stored.
      #
      # @return [Observatory::Execution::Request]
      #
      def initialize(trace_id:, request_id:, http_method:, path:)
        super(trace_id:)

        @request_id   = request_id
        @http_method  = http_method
        @path         = path
        @route        = nil
        @status       = nil
        @health_check = Observatory.config.health_check_paths.include?(path)
        @concurrent_at_start = 0
        @peak_concurrency = 0
      end

      # Record what the router resolved, once the controller has been reached.
      #
      # @param controller [String, nil] controller class name.
      # @param action [String, nil] action name.
      # @param route [String, nil] the matched route template.
      #
      # @return [void]
      #
      def resolve_route(controller: nil, action: nil, route: nil)
        @controller = controller if controller
        @action     = action if action
        @route      = route if route

        nil
      end

      # Record the classification of the client that made this request.
      #
      # @param client_id [String, nil] anonymised, rotating client identifier.
      # @param traffic_class [Symbol] the classifier's verdict.
      # @param user_agent [String, nil] the raw user agent, truncated.
      #
      # @return [void]
      #
      def classify(client_id:, traffic_class:, user_agent:)
        @client_id     = client_id
        @traffic_class = traffic_class
        @user_agent    = user_agent

        nil
      end

      # Record how long the request waited for a Rack thread, when the proxy
      # tells us.
      #
      # Only set when `X-Request-Start` (or `X-Queue-Start`) is present. This
      # application's proxy does not send it today, so the field is normally nil
      # and is rendered as "unknown" rather than zero — reporting an unmeasured
      # queue wait as zero would hide precisely the saturation this system exists
      # to detect.
      #
      # @param milliseconds [Float, nil] measured wait.
      #
      # @return [void]
      #
      def record_queue_wait(milliseconds)
        @queue_wait_ms = milliseconds

        nil
      end

      # Record the process's request concurrency as this request started.
      #
      # @param count [Integer] in-flight requests including this one.
      #
      # @return [void]
      #
      def record_concurrency(count)
        @concurrent_at_start = count
        @peak_concurrency = count if count > @peak_concurrency

        nil
      end

      # Raise the peak-concurrency watermark if another request pushed it higher
      # while this one was running.
      #
      # Lets a request's trace answer "what else was happening?" without joining
      # across traces — which matters when explaining that a request's GC and
      # allocation figures are contaminated by four concurrent threads.
      #
      # @param count [Integer] the observed in-flight count.
      #
      # @return [void]
      #
      def observe_concurrency(count)
        @peak_concurrency = count if count > @peak_concurrency

        nil
      end

      # Close the request with its response.
      #
      # @param status [Integer] the HTTP status returned.
      # @param response_bytes [Integer, nil] declared Content-Length.
      # @param pool_stat [Hash, nil] ActiveRecord connection-pool gauge at completion.
      #
      # @return [self]
      #
      def complete!(status:, response_bytes: nil, pool_stat: nil)
        @status         = status
        @response_bytes = response_bytes
        @pool_stat      = pool_stat

        finish!
      end

      # A stable label for grouping and baselines.
      #
      # Prefers the route template, falls back to `Controller#action`, and only
      # as a last resort — a request that never reached the router, such as a 404
      # or a Rack-level rejection — uses a coarsened path.
      #
      # @return [String]
      #
      def endpoint
        return @route if @route
        return "#{@controller}##{@action}" if @controller

        "#{@http_method} #{coarse_path}"
      end

      # Whether the request failed.
      #
      # Either an exception escaped (which `super` knows about) or the response
      # itself reported a server error. Both must count: an exception rescued by
      # `exceptions_app` into a rendered 500 page and an exception that escaped
      # Rack entirely are the same failure to an operator.
      #
      # @return [Boolean]
      #
      def error?
        super || (!@status.nil? && @status >= 500)
      end

      # Whether this request is one Observatory should never trace.
      #
      # @return [Boolean]
      #
      def ignored?
        Observatory.config.ignored_paths.any? do |pattern|
          pattern.is_a?(Regexp) ? pattern.match?(@path) : pattern == @path
        end
      end

    private

      # The request path with every numeric and long alphanumeric segment
      # replaced, so an unrouted path can still be grouped without carrying an
      # identifier.
      #
      # @return [String]
      #
      def coarse_path
        @path.gsub(%r{/\d+}, "/:id").gsub(%r{/[0-9a-f]{16,}}i, "/:token")
      end
    end
  end
end
