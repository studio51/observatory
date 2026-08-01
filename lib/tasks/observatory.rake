# frozen_string_literal: true

namespace :observatory do
  desc "Delete monitoring data that has outlived its retention window"
  task sweep: :environment do
    deleted = Observatory::Retention.sweep!

    deleted.each { |table, rows| puts format("  %-20s %8d rows deleted", table, rows) }
    puts "  #{deleted.values.sum} rows deleted in total"
  end

  desc "Flush any buffered monitoring events and rollups to the database now"
  task flush: :environment do
    events = Observatory::Pipeline::Writer.drain!(timeout: 30)
    buckets = Observatory::Pipeline::Aggregator.flush!

    puts "  #{events} events written, #{buckets} rollup buckets flushed"
  end

  desc "Take one dependency sample now (Puma, MySQL, Redis, Sidekiq)"
  task sample: :environment do
    result = Observatory::Sampler.tick!

    puts JSON.pretty_generate(result.transform_values { |value| value.respond_to?(:id) ? value.id : value })
  end

  desc "Report whether Observatory itself is healthy"
  task health: :environment do
    puts JSON.pretty_generate(Observatory::Runtime.health)
  end

  desc "Show the active configuration, with secrets omitted"
  task config: :environment do
    config = Observatory.config
    secret = %i[client_id_secret logger release_resolver]

    config.public_methods(false).grep(/=\z/).map { |writer| writer.to_s.delete_suffix("=").to_sym }.sort.each do |key|
      next unless config.respond_to?(key)

      value = secret.include?(key) ? "[filtered]" : config.public_send(key)
      puts format("  %-32s %s", key, value.inspect)
    end
  end
end

namespace :observatory do
  namespace :demo do
    desc "Reproduce the incident this system exists to explain (development only)"
    task incident: :environment do
      result = Observatory::Demo.reproduce_incident!

      puts "  #{result[:traces]} requests staged\n\n"
      puts result[:report]
      puts "\n  Open #{Rails.application.routes.url_helpers.devops_observatory_path rescue "/devops/observatory"}"
    end

    desc "List the available demonstration scenarios"
    task list: :environment do
      Observatory::Demo.scenarios.each { |name, description| puts format("  %-24s %s", name, description) }
    end

    desc "Run one scenario: rake observatory:demo:run[slow_sql]"
    task :run, [ :scenario ] => :environment do |_task, args|
      Observatory::Demo.run!(args[:scenario] || :cached_query_explosion)

      puts "  Scenario staged. Run `rake observatory:analyse` or open the dashboard."
    end

    desc "Delete every row the demonstration scenarios created"
    task clear: :environment do
      puts "  #{Observatory::Demo.clear!} demo rows deleted"
    end
  end

  desc "Run the detection rules now and print what they found"
  task analyse: :environment do
    findings = Observatory::Analysis::Engine.evaluate

    if findings.empty?
      puts "  No findings. Infrastructure being healthy is not the same as nothing being wrong,"
      puts "  so this means the rules ran and found nothing — not that they did not run."
    else
      puts findings.map(&:to_text).join("\n\n#{"=" * 78}\n\n")
    end
  end
end
