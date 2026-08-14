# frozen_string_literal: true

# A route that raises, so the suite can prove Observatory neither swallows the
# exception nor prevents Rails from responding to it.
#
class ErrorsController < ActionController::Base

  def internal_server_error
    raise "deliberate failure, raised so the trace of a failing request can be asserted"
  end
end
