# Install & setup

## Requirements

Rails 7.1–8.x and Ruby 3.2+. Puma, Sidekiq, MySQL and Redis are each detected
at boot and instrumented through a guarded adapter, so Observatory installs
cleanly into an application that uses none of them.

## Quick start

```ruby
gem "studio51-observatory"
```

Mount it wherever your application puts operator tooling, behind whatever gate
that tooling already sits behind — Observatory ships no authentication of its
own, on purpose:

```ruby
# config/routes.rb
mount(Observatory::Engine, at: "/observatory", as: :observatory)
```

```ruby
# config/initializers/observatory.rb
Observatory.configure do |config|
  config.parent_controller = "Admin::ApplicationController"
end
```

```ruby
# config/initializers/observatory.rb
Observatory.configure do |config|
  config.enabled = true
  config.normal_request_sample_rate = 0.01
  config.slow_request_threshold     = 1.second
  config.high_query_count           = 1_000
  config.client_id_secret           = Rails.application.secret_key_base
end
```

Every knob can be overridden from the environment, and the override is applied
*after* the block so it always wins. The one to remember during an incident:

```sh
OBSERVATORY_ENABLED=0
```


## Development

The suite runs against a dummy Rails application under `test/dummy`, on SQLite —
which also exercises the path a host without MySQL takes.

```sh
bundle install
bundle exec rake            # the suite
bundle exec rake benchmark  # the overhead budgets, which need a quiet machine
bundle exec rubocop
```
