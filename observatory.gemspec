# frozen_string_literal: true

require_relative "lib/observatory/version"

Gem::Specification.new do |spec|
  spec.name        = "observatory"
  spec.version     = Observatory::VERSION
  spec.authors     = [ "Vlad Radulescu" ]
  spec.email       = [ "vlad@studio51.solutions" ]
  spec.homepage    = "https://github.com/studio51/observatory"
  spec.summary     = "Causal observability and application monitoring for Rails."
  spec.description = <<~TEXT.freeze
    Observatory explains what a Rails application is doing internally, not merely
    whether its infrastructure is online. It correlates HTTP requests, Sidekiq
    jobs, health checks, watchdog actions and deployments into single execution
    records, separates ActiveRecord query-cache work from real database
    execution, accounts for Puma request capacity in thread-seconds, and runs a
    deterministic rule engine that names the constrained resource, the workload
    consuming it, and the evidence for and against that conclusion.
  TEXT
  # Inherited from the host repository. Publishing this as an open-source gem is
  # a deliberate decision for the maintainer to take at extraction time; until
  # then it carries the same terms as everything else in games.directory.
  #
  spec.license = "Nonstandard"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "{app,config,db,lib}/**/*",
    "LICENSE",
    "README.md",
    "CHANGELOG.md",
  ]

  # Hard dependencies. Observatory is a Rails engine and renders its dashboard
  # with ViewComponent; everything else it observes is optional.
  #
  spec.add_dependency "rails", ">= 7.1", "< 9"
  spec.add_dependency "view_component", ">= 3.0"

  # Puma, Sidekiq, mysql2 and redis are deliberately NOT dependencies. Each is
  # detected at boot and instrumented through a guarded adapter, so Observatory
  # installs cleanly in an application that uses none of them.
end
