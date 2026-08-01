# frozen_string_literal: true

module Observatory
  module Middleware

    # The Rack boundary: opens a request context, and closes it whatever happens.
    #
    # Mounted high in the stack (immediately after `ActionDispatch::RequestId`, so
    # the request id exists) and therefore measuring almost the whole of Rack, not
    # just the controller. The difference is not academic — time spent in
    # `Rack::Attack`, in CORS, in session loading and in the router is real time
    # holding a real Puma thread, and a system built to explain thread exhaustion
    # has to count it.
    #
    # ## What it does not do
    #
    # It does not rescue exceptions. It records them and re-raises, so Rails'
    # exception handling, the `exceptions_app` error pages and Sentry all behave
    # exactly as they did before Observatory was installed. The `ensure` block
    # closes the context on every path — normal return, raise, or a `throw` from
    # `catch(:halt)`-style control flow.
    #
    # ## Cost
    #
    # Two `GC.stat` reads, a monotonic clock read, a mutex-guarded hash insert and
    # its matching delete. The measured overhead is in
    # `test/performance/overhead_test.rb`; the budget it is held to is under one
    # millisecond at the median.
    #
    class RequestTracker
      REQUEST_ID    = "action_dispatch.request_id".freeze
      HTTP_X_REQUEST_START = "HTTP_X_REQUEST_START".freeze
      HTTP_X_QUEUE_START   = "HTTP_X_QUEUE_START".freeze
      PATH_INFO     = "PATH_INFO".freeze
      METHOD        = "REQUEST_METHOD".freeze
      USER_AGENT    = "HTTP_USER_AGENT".freeze
      CONTENT_LENGTH = "Content-Length".freeze
      TRACE_HEADER  = "X-Observatory-Trace".freeze

      # @param app [#call] the next application in the Rack stack.
      #
      # @return [Observatory::Middleware::RequestTracker]
      #
      def initialize(app)
        @app = app
      end

      # Measure one request.
      #
      # @param env [Hash] the Rack environment.
      #
      # @return [Array(Integer, Hash, #each)] the Rack response, untouched.
      #
      def call(env)
        return @app.call(env) unless Observatory.enabled?

        context = Safely.call("middleware.start") { start(env) }
        return @app.call(env) if context.nil?

        dispatch(env, context)
      end

    private

      # Run the request with its context installed, closing it on every exit path.
      #
      # @param env [Hash] the Rack environment.
      # @param context [Observatory::Execution::Request] the context to install.
      #
      # @return [Array(Integer, Hash, #each)] the Rack response.
      #
      def dispatch(env, context)
        status, headers, body = nil

        Current.with(context) do
          Capacity.enter(context).then { |count| context.record_concurrency(count) }

          begin
            status, headers, body = @app.call(env)
          rescue Exception => exception # rubocop:disable Lint/RescueException
            Safely.call("middleware.exception") { context.record_exception(exception) }

            raise
          ensure
            Safely.call("middleware.finish") { finish(env, context, status, headers) }
            Capacity.leave(context)
          end
        end

        headers[TRACE_HEADER] = context.trace_id if headers.is_a?(Hash) && Observatory.config.demo_enabled

        [ status, headers, body ]
      end

      # Build the request context.
      #
      # Returns nil for paths Observatory is configured to ignore — assets and
      # the Vite dev server, whose traces would be pure noise and would dominate
      # the sample.
      #
      # @param env [Hash] the Rack environment.
      #
      # @return [Observatory::Execution::Request, nil]
      #
      def start(env)
        path = env[PATH_INFO].to_s

        context = Execution::Request.new(
          trace_id:    Trace.generate,
          request_id:  env[REQUEST_ID],
          http_method: env[METHOD].to_s,
          path:,
        )

        return nil if context.ignored?

        context.record_queue_wait(queue_wait_ms(env))

        context
      end

      # Close the request: classify the client, sample the pool, hand the trace to
      # the pipeline.
      #
      # Classification happens here rather than at entry so it costs nothing for
      # a request that is never retained.
      #
      # @param env [Hash] the Rack environment.
      # @param context [Observatory::Execution::Request] the context to close.
      # @param status [Integer, nil] the response status; nil when the stack raised.
      # @param headers [Hash, nil] the response headers.
      #
      # @return [void]
      #
      def finish(env, context, status, headers)
        user_agent = env[USER_AGENT]

        context.classify(
          client_id:     Traffic::ClientIdentity.call(client_address(env)),
          traffic_class: Traffic::Classifier.call(
            user_agent:, path: env[PATH_INFO].to_s, authenticated: authenticated?(env),
          ),
          user_agent: user_agent&.slice(0, 255),
        )

        context.complete!(
          status:         status || 500,
          response_bytes: response_bytes(headers),
          pool_stat:      Probes::Database.pool_stat,
        )

        Pipeline.submit(context)

        nil
      end

      # Time the request spent waiting for a Rack thread, when the proxy reports it.
      #
      # This application's proxy does not set `X-Request-Start` today, so this is
      # normally nil — and nil is reported as *unknown*, never as zero. Reporting
      # an unmeasured queue wait as zero would erase the single clearest signal
      # that requests are queueing behind saturated threads, which is the failure
      # this system exists to catch. The moment the proxy starts sending the
      # header, this starts working with no code change.
      #
      # @param env [Hash] the Rack environment.
      #
      # @return [Float, nil] milliseconds waited, or nil when unmeasurable.
      #
      def queue_wait_ms(env)
        raw = env[HTTP_X_REQUEST_START] || env[HTTP_X_QUEUE_START]
        return nil if raw.nil?

        # Proxies send "t=1690000000.123", "1690000000123" (ms) or seconds.
        #
        digits = raw.to_s[/[\d.]+/]
        return nil if digits.nil?

        started = digits.to_f
        started /= 1_000.0 if started > 10_000_000_000.0
        waited = (Time.now.to_f - started) * 1_000.0

        waited.negative? || waited > 300_000.0 ? nil : waited.round(3)
      end

      # The client address, for anonymisation.
      #
      # Read through `ActionDispatch::Request` so it honours the application's
      # trusted-proxy configuration rather than trusting `X-Forwarded-For`
      # blindly. The value never leaves this method — only its HMAC is stored.
      #
      # @param env [Hash] the Rack environment.
      #
      # @return [String, nil]
      #
      def client_address(env)
        return nil unless defined?(ActionDispatch::Request)

        ActionDispatch::Request.new(env).ip
      rescue StandardError
        nil
      end

      # Whether a signed-in user made this request.
      #
      # Read from Warden's env key without touching the session or the database —
      # asking Devise for `current_user` here would issue a query on the request
      # path, which is precisely what Observatory must not do.
      #
      # @param env [Hash] the Rack environment.
      #
      # @return [Boolean]
      #
      def authenticated?(env)
        warden = env["warden"]

        !warden.nil? && warden.respond_to?(:authenticated?) && warden.authenticated?
      rescue StandardError
        false
      end

      # The declared response size, when the response declares one.
      #
      # @param headers [Hash, nil] the response headers.
      #
      # @return [Integer, nil] bytes.
      #
      def response_bytes(headers)
        return nil unless headers.is_a?(Hash)

        length = headers[CONTENT_LENGTH] || headers["content-length".freeze]

        length && length.to_i
      end
    end
  end
end
