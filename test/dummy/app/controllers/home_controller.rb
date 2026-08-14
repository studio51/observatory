# frozen_string_literal: true

# The dummy application's root.
#
# Deliberately issues the same lookup twice: the first executes, the second is
# served by the ActiveRecord query cache. That split is the distinction
# Observatory exists to draw, so the end-to-end test needs a request that
# actually produces both kinds.
#
class HomeController < ActionController::Base

  def index
    @count = User.count
    @first = User.order(:id).first
    @again = User.order(:id).first # query cache

    render plain: "users:#{ @count }"
  end
end
