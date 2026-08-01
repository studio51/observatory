# frozen_string_literal: true

module Observatory
  module Analysis

    # Runs the rules and turns their findings into incidents.
    #
    # ## The cycle
    #
    #   window loads once  ->  every applicable rule reasons over it
    #                      ->  findings become or update incidents
    #                      ->  incidents nobody has seen recently are resolved
    #
    # Each step is deliberate:
    #
    # **One window.** Fourteen rules querying independently would cost fourteen
    # times the work and — worse — could disagree with each other about what the
    # busy-thread count was, producing two contradictory findings from one
    # moment.
    #
    # **Findings deduplicate into incidents.** A saturation lasting ten minutes
    # is one incident whose `last_seen_at` advances and whose `occurrence_count`
    # climbs, not forty identical rows. Otherwise the dashboard becomes the noise
    # it was built to replace.
    #
    # **Incidents auto-resolve.** An incident whose rule has stopped firing for
    # long enough is closed with its `ended_at` set. An operator should be able
    # to trust that an open incident is a current one.
    #
    # **A rule that raises does not stop the cycle.** Each is wrapped
    # individually, so a bug in one rule costs that rule's findings and nothing
    # else.
    #
    class Engine
      RESOLVE_AFTER = 600   # an incident unseen for ten minutes is over

      class << self

        # The registered rules, in evaluation order.
        #
        # Order is presentational rather than semantic — rules do not depend on
        # one another — but the capacity rules come first so that, when several
        # fire at once, the headline is the constrained resource rather than a
        # downstream symptom.
        #
        # @return [Array<Class>]
        #
        def rules
          @rules ||= [
            Rules::PumaSaturation,
            Rules::HealthCheckBlocked,
            Rules::WatchdogMisclassification,
            Rules::CachedQueryExplosion,
            Rules::ExecutedQueryExplosion,
            Rules::SlowSql,
            Rules::DatabasePoolStarvation,
            Rules::GcPressure,
            Rules::QueueDrainRegression,
            Rules::HealthyBacklog,
            Rules::RedisSaturation,
            Rules::CrawlerAmplification,
            Rules::DeploymentRegression,
          ]
        end

        # Register an additional rule.
        #
        # The extension point for application-specific detection — a host that
        # knows something Observatory cannot infer can add a rule without
        # forking the engine.
        #
        # @param rule_class [Class] a {Observatory::Analysis::Rule} subclass.
        #
        # @return [Array<Class>] the registered rules.
        #
        def register(rule_class)
          rules << rule_class unless rules.include?(rule_class)

          rules
        end

        # Evaluate every applicable rule against a window.
        #
        # Does not touch the database beyond loading the window — useful for
        # testing a rule, and for the rake task that prints findings without
        # recording them.
        #
        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Array<Observatory::Analysis::Finding>]
        #
        def evaluate(window = Window.new)
          return [] unless Observatory.config.analysis_enabled

          window.preload!

          rules.flat_map do |rule_class|
            rule = rule_class.new
            next [] unless rule.applicable?

            Safely.call("analysis.#{rule.key}", fallback: []) { Array(rule.call(window)) }
          end
        end

        # Run one detection cycle and record what it found.
        #
        # @param window [Observatory::Analysis::Window] the measurements to reason over.
        #
        # @return [Hash{Symbol => Integer}] what changed.
        #
        def run!(window = Window.new)
          return { findings: 0, opened: 0, updated: 0, resolved: 0 } unless Observatory.config.analysis_enabled

          Safely.call("analysis.run", fallback: {}) do
            Instrumentation.suppress do
              findings = evaluate(window)
              opened, updated = record(findings)

              { findings: findings.size, opened:, updated:, resolved: resolve_stale!(window.to) }
            end
          end
        end

        # Turn findings into incident rows.
        #
        # @param findings [Array<Observatory::Analysis::Finding>] what the rules found.
        #
        # @return [Array(Integer, Integer)] incidents opened and updated.
        #
        def record(findings)
          opened = 0
          updated = 0

          findings.each do |found|
            incident = Incident.find_by(fingerprint: found.fingerprint, status: Incident::OPEN)

            if incident
              refresh(incident, found)
              updated += 1
            else
              open(found)
              opened += 1
            end
          end

          [ opened, updated ]
        end

        # Close incidents whose rule has stopped firing.
        #
        # @param now [Time] the end of the current window.
        #
        # @return [Integer] incidents resolved.
        #
        def resolve_stale!(now = Clock.wall)
          Incident.open_incidents
                  .where(last_seen_at: ...(now - RESOLVE_AFTER))
                  .find_each
                  .count { |incident| incident.resolve!(at: now, notes: "No longer detected.") }
        end

      private

        # Create an incident and its evidence.
        #
        # @param found [Observatory::Analysis::Finding] the finding to record.
        #
        # @return [Observatory::Incident]
        #
        def open(found)
          incident = Incident.create!(
            fingerprint: found.fingerprint,
            rule:        found.rule.to_s,
            title:       found.title[0, 255],
            severity:    found.severity.to_s,
            status:      Incident::OPEN,
            started_at:  found.started_at,
            ended_at:    found.ended_at,
            last_seen_at: Clock.wall,
            component:   found.component,
            constrained_resource: found.constrained_resource,
            primary_contributor:  found.primary_contributor&.slice(0, 255),
            failure_mode: found.failure_mode&.slice(0, 255),
            confidence:  found.confidence.to_s,
            impact:      found.impact,
            recommended_action: found.recommended_action,
            release:     Release.current,
            deployment_id: Deployment.at(found.started_at)&.id,
            summary:     found.subjects,
          )

          write_evidence(incident, found)
          link_subjects(incident, found)

          incident
        end

        # Update an ongoing incident with the latest evidence.
        #
        # Evidence is replaced rather than appended: an incident should show what
        # is true *now*, not a growing log of every reading since it opened. The
        # timeline is reconstructed from the linked traces and samples, which
        # keep their own timestamps.
        #
        # @param incident [Observatory::Incident] the ongoing incident.
        # @param found [Observatory::Analysis::Finding] the latest finding.
        #
        # @return [Observatory::Incident]
        #
        def refresh(incident, found)
          incident.update!(
            last_seen_at:     Clock.wall,
            occurrence_count: incident.occurrence_count + 1,
            severity:         escalate(incident.severity, found.severity),
            confidence:       found.confidence.to_s,
            impact:           found.impact,
            summary:          found.subjects,
          )

          incident.evidence.delete_all
          write_evidence(incident, found)
          link_subjects(incident, found)

          incident
        end

        # @param incident [Observatory::Incident] the incident.
        # @param found [Observatory::Analysis::Finding] the finding.
        #
        # @return [void]
        #
        def write_evidence(incident, found)
          rows = []

          found.supporting.each_with_index do |item, index|
            rows << item.to_row(incident_id: incident.id, position: index)
          end
          found.contradicting.each_with_index do |item, index|
            rows << item.to_row(incident_id: incident.id, position: index)
          end

          IncidentEvidence.insert_all(rows) if rows.any?

          nil
        end

        # Attach the traces, samples and events the finding rests on, so the
        # incident page can show them without re-deriving anything.
        #
        # @param incident [Observatory::Incident] the incident.
        # @param found [Observatory::Analysis::Finding] the finding.
        #
        # @return [void]
        #
        def link_subjects(incident, found)
          RequestTrace.where(id: found.subjects[:request_traces]).update_all(incident_id: incident.id) if
            found.subjects[:request_traces].present?
          JobTrace.where(id: found.subjects[:job_traces]).update_all(incident_id: incident.id) if
            found.subjects[:job_traces].present?
          WatchdogEvent.where(id: found.subjects[:watchdog_events]).update_all(incident_id: incident.id) if
            found.subjects[:watchdog_events].present?

          nil
        end

        # Keep the worst severity an incident has reached.
        #
        # An incident that was critical for a minute and is merely a warning now
        # is still an incident that was critical, and downgrading it would hide
        # that from anyone reading the list afterwards.
        #
        # @param current [String] the incident's severity.
        # @param found [Symbol] the latest finding's severity.
        #
        # @return [String]
        #
        def escalate(current, found)
          order = Incident::SEVERITY_ORDER

          order.fetch(found.to_s, 3) < order.fetch(current, 3) ? found.to_s : current
        end
      end
    end
  end
end
