# frozen_string_literal: true

require "securerandom"

module Observatory

  # Correlation identifiers.
  #
  # The brief lists a dozen identifiers a record might carry — `request_id`,
  # `job_id`, `deployment_id`, `worker_id` and so on — and then asks that new
  # ones not be minted where an existing one will do. That instruction does most
  # of the design work:
  #
  # - **`request_id`** is Rails', set by `ActionDispatch::RequestId` and already
  #   in this application's log tags. Reused as-is.
  # - **`job_id`** is Sidekiq's `jid`. Reused as-is.
  # - **`batch_id`** is Sidekiq's `bid`, when a batch exists. Reused as-is.
  # - **`release_id`** is the deployed SHA `bin/dev` records. Reused as-is.
  # - **`process_id`** is the OS pid; **`thread_id`** is the thread's object id.
  # - **`incident_id`** is the primary key of the incident row.
  #
  # That leaves exactly one identifier Observatory has to mint itself: a
  # **trace id** that is present for *every* kind of execution, including the
  # ones Rails has no id for — a health check, a watchdog probe, a background
  # sample. Everything else is borrowed.
  #
  module Trace
    BYTES = 8   # 64 bits: collision-free at any volume this system will see

    module_function

    # A new trace identifier.
    #
    # `SecureRandom.hex` rather than a counter or a UUID: a counter would collide
    # across three Puma workers and two Sidekiq processes, and a full UUID would
    # cost 36 bytes per row for no extra safety at this cardinality.
    #
    # @return [String] 16 hex characters.
    #
    def generate
      SecureRandom.hex(BYTES)
    end
  end
end
