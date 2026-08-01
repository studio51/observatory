# frozen_string_literal: true

module Observatory
  module Traffic

    # Sorts traffic into a small number of conservative classes.
    #
    # The point is not bot detection — it is attribution of cost. When eighty-three
    # requests from one unknown crawler generate 3.2 million queries and six
    # hundred thread-seconds, the useful sentence is "an unknown datacenter
    # crawler is consuming your request capacity", and that requires only a
    # coarse, honest classification.
    #
    # Conservative on purpose: anything not clearly identifiable is `:unknown`
    # rather than guessed. A wrong "suspicious automation" label on real users
    # would be worse than no label, because someone would act on it.
    #
    module Classifier

      # User-agent fragments that identify a crawler operated by a search engine
      # or another well-known service. Matched case-insensitively.
      #
      KNOWN_CRAWLERS = {
        "googlebot"        => :search_crawler,
        "google-inspectiontool" => :search_crawler,
        "bingbot"          => :search_crawler,
        "slurp"            => :search_crawler,
        "duckduckbot"      => :search_crawler,
        "baiduspider"      => :search_crawler,
        "yandexbot"        => :search_crawler,
        "applebot"         => :search_crawler,
        "facebookexternalhit" => :social_crawler,
        "twitterbot"       => :social_crawler,
        "linkedinbot"      => :social_crawler,
        "discordbot"       => :social_crawler,
        "slackbot"         => :social_crawler,
        "whatsapp"         => :social_crawler,
        "telegrambot"      => :social_crawler,
        "gptbot"           => :ai_crawler,
        "claudebot"        => :ai_crawler,
        "anthropic-ai"     => :ai_crawler,
        "ccbot"            => :ai_crawler,
        "perplexitybot"    => :ai_crawler,
        "bytespider"       => :ai_crawler,
        "amazonbot"        => :ai_crawler,
        "ahrefsbot"        => :seo_crawler,
        "semrushbot"       => :seo_crawler,
        "mj12bot"          => :seo_crawler,
        "dotbot"           => :seo_crawler,
        "petalbot"         => :seo_crawler,
        "dataforseobot"    => :seo_crawler,
      }.freeze

      # Fragments that mark automation without identifying who runs it.
      # A request carrying one of these is a script, but not one that announced
      # itself as a crawler — so it is classified as unknown automation, not as a
      # crawler.
      #
      GENERIC_AUTOMATION = %w[
        bot crawler spider scraper curl wget python-requests python-urllib
        go-http-client java/ okhttp axios node-fetch libwww-perl httpclient
        headlesschrome phantomjs scrapy
      ].freeze

      # Fragments that identify an internal probe rather than external traffic.
      #
      MONITORING_AGENTS = %w[
        uptimerobot pingdom statuscake newrelicpinger datadog site24x7
        betteruptime healthcheck kube-probe elb-healthchecker
      ].freeze

      # Fragments that identify a real browser engine.
      #
      BROWSER_ENGINES = %w[mozilla/ applewebkit gecko/ chrome/ safari/ firefox/ edge/].freeze

      class << self

        # Classify one request.
        #
        # @param user_agent [String, nil] the raw User-Agent header.
        # @param path [String] the request path, used to spot health probes.
        # @param authenticated [Boolean] whether a signed-in user made the request.
        #
        # @return [Symbol] one of :health_check, :authenticated_user, :search_crawler,
        #   :social_crawler, :ai_crawler, :seo_crawler, :monitoring, :api_client,
        #   :unknown_automation, :human or :unknown.
        #
        def call(user_agent:, path:, authenticated: false)
          return :health_check if health_check_path?(path)

          agent = user_agent.to_s.downcase
          return :unknown if agent.empty?

          known = KNOWN_CRAWLERS.find { |fragment, _| agent.include?(fragment) }
          return known.last if known

          return :monitoring if MONITORING_AGENTS.any? { |fragment| agent.include?(fragment) }
          return :unknown_automation if GENERIC_AUTOMATION.any? { |fragment| agent.include?(fragment) }

          return :authenticated_user if authenticated
          return :human if BROWSER_ENGINES.any? { |fragment| agent.include?(fragment) }

          :api_client
        end

        # Whether a class of traffic is automated rather than a person at a browser.
        #
        # @param traffic_class [Symbol] a value returned by {call}.
        #
        # @return [Boolean]
        #
        def automated?(traffic_class)
          !%i[human authenticated_user unknown].include?(traffic_class)
        end

        # The user-agent family, for grouping in the dashboard.
        #
        # Deliberately crude — the full user agent is high-cardinality and
        # semi-identifying, and nothing in the analysis needs more than a family
        # name.
        #
        # @param user_agent [String, nil] the raw User-Agent header.
        #
        # @return [String] a short family name, or "unknown".
        #
        def family(user_agent)
          agent = user_agent.to_s.downcase
          return "unknown".freeze if agent.empty?

          known = KNOWN_CRAWLERS.keys.find { |fragment| agent.include?(fragment) }
          return known if known

          case agent
          when /edg\//    then "edge".freeze
          when /chrome\// then "chrome".freeze
          when /firefox\// then "firefox".freeze
          when /safari\// then "safari".freeze
          else                 "other".freeze
          end
        end

      private

        # @param path [String] the request path.
        #
        # @return [Boolean] whether the path is a configured health endpoint.
        #
        def health_check_path?(path)
          Observatory.config.health_check_paths.include?(path)
        end
      end
    end
  end
end
