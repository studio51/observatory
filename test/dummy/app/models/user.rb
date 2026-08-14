# frozen_string_literal: true

# The dummy application's one model.
#
# It exists so the integration tests have something to query: a request that
# issues no SQL cannot demonstrate that executed lookups are separated from
# query-cache hits, which is the claim those tests are there to prove.
#
class User < ActiveRecord::Base
end
