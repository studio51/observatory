# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The dummy application the engine mounts into during tests. SQLite keeps CI
# free of a database service, and it exercises the path a host without MySQL
# takes: the MySQL probe detects the adapter and disables itself.
#
gem "sqlite3"

group :development, :test do
  gem "rake"
  gem "minitest"
  gem "puma"

  # Sidekiq is not a runtime dependency — the engine instruments it only when
  # the host has it. It is here so that optional path is a tested one.
  #
  gem "sidekiq"

  gem "rubocop", ">= 1.80", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rails-omakase", require: false

  # Studio51 house RuboCop cops (doc-block shape + method breathing room).
  #
  gem "rubocop-studio51", github: "studio51/standards",
                          glob: "rubocop-studio51/*.gemspec",
                          require: false,
                          ref: "08cf49d9c3fe8d559d587a4836b36d3e58600e57"
end
