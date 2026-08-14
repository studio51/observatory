# frozen_string_literal: true

require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"

PERFORMANCE_TESTS = "test/lib/observatory/performance/**/*_test.rb"

# The overhead benchmarks assert wall-clock budgets, which a shared CI runner
# cannot honour. They are a local instrument, not a gate — `rake benchmark`.
#
Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.test_files = FileList["test/**/*_test.rb"].exclude(PERFORMANCE_TESTS)
  task.warning = false
  task.verbose = false
end

Rake::TestTask.new(:benchmark) do |task|
  task.libs << "test"
  task.pattern = PERFORMANCE_TESTS
  task.warning = false
  task.verbose = false
end

task default: :test
