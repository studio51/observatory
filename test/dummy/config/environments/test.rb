# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load       = false

  config.consider_all_requests_local       = true
  config.action_controller.perform_caching = false
  config.action_dispatch.show_exceptions   = :none

  config.active_support.deprecation = :stderr

  config.cache_store = :memory_store
end

# Observatory collects nothing by default here, for the same reason it does in
# any host's test environment: a suite that measures itself is measuring noise,
# and parallel workers would contend on the buffer. Tests opt in per-example
# with `with_observatory`, which restores the previous configuration afterwards.
#
Observatory.configure do |config|
  config.enabled        = false
  config.persist        = false
  config.log_events     = false
  config.probes_enabled = false
  config.writer_enabled = false

  config.client_id_secret = "observatory-dummy-client-id-secret"
end
