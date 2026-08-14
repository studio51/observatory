# frozen_string_literal: true

# A route with a dynamic segment.
#
# `/users/:id` is what proves Observatory stores the route *template* and not
# the literal path — the privacy claim in the README, and the only way per-route
# rollups can group anything.
#
class UsersController < ActionController::Base

  def show
    @user = User.find(params[:id])

    render plain: @user.name
  end
end
