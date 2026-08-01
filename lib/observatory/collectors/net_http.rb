# frozen_string_literal: true

require "net/http"

module Observatory
  module Collectors

    # Instruments outbound HTTP.
    #
    # This application talks to Steam, PlayStation Network, Xbox Live, Epic, GOG,
    # CEX and others through `Net::HTTP` — there is no Faraday or HTTParty layer
    # to hook, so the transport itself is where the measurement has to go.
    #
    # The question it answers is the one that separates "our job is slow" from
    # "their API is slow": when a sync job takes four minutes, was that four
    # minutes of our code, or four minutes of waiting for someone else's server?
    # Without this, both look identical — time inside the job, attributable to
    # nothing.
    #
    # ## What is deliberately not captured
    #
    # No URL paths, no query strings, no headers, no request bodies, no response
    # bodies. Every one of those carries credentials in this application: Steam
    # puts the API key in the query string, PSN and Xbox put bearer tokens in
    # headers. Only the **host**, the method, the status and the duration are
    # recorded — enough to attribute cost to a vendor, not enough to leak
    # anything.
    #
    # ## Implementation
    #
    # `Net::HTTP#request` is wrapped with a prepended module rather than an alias
    # chain, so the original stays reachable via `super` and a second wrapper
    # (Sentry's breadcrumb logger already wraps this method) composes correctly
    # instead of clobbering it.
    #
    module NetHttp
      MILLISECOND = 1_000.0

      # Wraps `Net::HTTP#request` to time the call and attribute it to a host.
      #
      module Instrumented

        # Time one outbound request.
        #
        # Falls through to the original method untouched when Observatory is off,
        # suppressed, or nothing is being measured — so the overhead on an
        # unmonitored call is one method call and two hash reads.
        #
        # @param request [Net::HTTPRequest] the request being sent.
        # @param body [String, nil] the request body, passed straight through.
        # @param args [Array] any remaining positional arguments.
        #
        # @yield the block `Net::HTTP#request` yields the response to.
        #
        # @return [Net::HTTPResponse] whatever the original returned.
        #
        def request(request, body = nil, *args, &block)
          context = Observatory.enabled? ? Current.execution : nil
          return super if context.nil?

          started  = Clock.monotonic
          response = nil
          failed   = false

          begin
            response = super
          rescue StandardError
            failed = true

            raise
          ensure
            Observatory::Collectors::NetHttp.record(context:, request:, started:, failed:, response:)
          end

          response
        end
      end

      class << self

        # Prepend the instrumentation onto `Net::HTTP`.
        #
        # Idempotent: prepending twice would double-count, so the module tracks
        # whether it has already been installed.
        #
        # @return [void]
        #
        def install!
          return if @installed

          ::Net::HTTP.prepend(Instrumented)
          @installed = true

          nil
        end

        # Whether the instrumentation is in place.
        #
        # @return [Boolean]
        #
        def installed?
          @installed == true
        end

        # Record one outbound call against the execution in progress.
        #
        # @param context [Observatory::Execution::Base] the execution to charge.
        # @param request [Net::HTTPRequest] the request that was sent.
        # @param started [Float] monotonic time the call began.
        # @param failed [Boolean] whether the call raised.
        # @param response [Net::HTTPResponse, nil] the response, when there was one.
        #
        # @return [void]
        #
        def record(context:, request:, started:, failed:, response: nil)
          Safely.call("collectors.net_http.record") do
            context.record_external_call(
              host:        host_for(request),
              duration_ms: (Clock.monotonic - started) * MILLISECOND,
              status:      response.respond_to?(:code) ? response.code.to_i : nil,
              error:       failed,
            )
          end

          nil
        end

      private

        # The destination host, with no path, query or credentials.
        #
        # @param request [Net::HTTPRequest] the request that was sent.
        #
        # @return [String] the host, or "unknown" when it cannot be read.
        #
        def host_for(request)
          uri = request.respond_to?(:uri) ? request.uri : nil
          return uri.host if uri.respond_to?(:host) && uri.host

          header = request.respond_to?(:[]) ? request["host"] : nil
          return header.split(":".freeze).first if header

          "unknown".freeze
        end
      end
    end
  end
end
