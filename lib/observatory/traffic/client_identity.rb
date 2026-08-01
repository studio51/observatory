# frozen_string_literal: true

require "openssl"

module Observatory
  module Traffic

    # Turns a client address into a correlatable identifier that is not the
    # address.
    #
    # Observatory needs to say "these eighty-three requests came from the same
    # client and cost you six hundred thread-seconds". It does not need to know,
    # or store, who that client is. An HMAC over the address gives the first
    # property without the second.
    #
    # ## Why an HMAC and not a hash
    #
    # A plain SHA of an IPv4 address is reversible in seconds — the entire space
    # is 2^32 and a rainbow table fits on a laptop. Keyed with a secret the
    # attacker does not have, it is not.
    #
    # ## Why the salt rotates
    #
    # A fixed key would let identifiers be correlated across months, which is
    # tracking. The salt includes a time window (`client_id_rotation`, one day by
    # default), so an identifier is stable for as long as an investigation needs
    # and meaningless after that.
    #
    # If no secret is configured the whole mechanism turns itself off and returns
    # nil, because a predictable "anonymisation" is worse than none — it looks
    # safe.
    #
    module ClientIdentity
      DIGEST = "SHA256".freeze
      LENGTH = 16   # hex characters kept; 64 bits is ample to distinguish clients

      class << self

        # An anonymised, rotating identifier for a client address.
        #
        # @param address [String, nil] the client address, never stored.
        # @param at [Time] the time to derive the rotation window from.
        #
        # @return [String, nil] a short hex identifier, or nil when no secret is
        #   configured or no address was given.
        #
        def call(address, at: Time.now)
          return nil if address.nil? || address.empty?

          secret = Observatory.config.client_id_secret
          return nil if secret.nil? || secret.empty?

          OpenSSL::HMAC.hexdigest(DIGEST, secret, "#{window(at)}:#{address}")[0, LENGTH]
        end

        # Whether anonymised client identifiers are available in this process.
        #
        # The dashboard uses this to explain an empty client column rather than
        # implying there was no traffic.
        #
        # @return [Boolean]
        #
        def available?
          secret = Observatory.config.client_id_secret

          !secret.nil? && !secret.empty?
        end

      private

        # The rotation window a timestamp falls into.
        #
        # @param at [Time] the timestamp.
        #
        # @return [Integer] the window index.
        #
        def window(at)
          rotation = Observatory.config.client_id_rotation.to_i
          return 0 if rotation <= 0

          at.to_i / rotation
        end
      end
    end
  end
end
