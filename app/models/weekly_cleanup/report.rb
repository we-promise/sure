# Builds the deterministic markdown report seeded into the proactive cleanup
# chat. Structured like a short assistant message: a one-line summary, then a
# section per detector with counts and concrete examples. No LLM involved —
# every number and name comes straight from the detectors.
class WeeklyCleanup::Report
  def self.markdown(family:, findings:)
    new(family:, findings:).markdown
  end

  def initialize(family:, findings:)
    @family = family
    @findings = findings
  end

  def markdown
    parts = [ intro ]
    parts << clean_bill_of_health if findings.empty?
    findings.each { |f| parts << section(f) }
    parts << outro
    parts.join("\n\n")
  end

  def title(date = Date.current)
    I18n.t("weekly_cleanup.chat_title", date: I18n.l(WeeklyCleanupRun.period_for(date), format: :long))
  end

  def summary
    findings.to_h { |f| [ f.key, f.count ] }
  end

  private
    attr_reader :family, :findings

    def intro
      I18n.t("weekly_cleanup.intro", count: findings.size)
    end

    def clean_bill_of_health
      I18n.t("weekly_cleanup.clean")
    end

    def section(finding)
      lines = [ "### #{finding.heading}" ]
      lines.concat(finding.samples.map { |s| "- #{s}" })
      lines.join("\n")
    end

    def outro
      I18n.t("weekly_cleanup.outro")
    end
end
