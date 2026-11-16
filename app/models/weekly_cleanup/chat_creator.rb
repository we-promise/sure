# Creates the proactive weekly cleanup chat: one user-owned Chat per family
# admin, seeded with a single complete assistant message containing the
# deterministic findings report. Idempotent per admin per weekly period via
# WeeklyCleanupRun — reruns skip admins who already have this week's chat.
class WeeklyCleanup::ChatCreator
  def self.call(family:, period_start: WeeklyCleanupRun.period_for(family.local_date))
    new(family:, period_start:).call
  end

  def initialize(family:, period_start:)
    @family = family
    @period_start = period_start
  end

  def call
    created = []

    admins.each do |user|
      next if WeeklyCleanupRun.exists?(family:, user:, period_start:)

      # Findings are built per admin so an account they can't access never
      # shows up by name in their chat.
      findings = collect_findings(user)
      # A failed detector must not look like a clean week or burn the period:
      # skip so the next run retries.
      next if findings.nil?

      report = WeeklyCleanup::Report.new(family:, findings:)
      chat = nil
      WeeklyCleanupRun.transaction do
        chat = user.chats.create!(
          title: report.title(period_start),
          messages: [ AssistantMessage.new(content: report.markdown, ai_model: Chat.default_model, status: :complete) ]
        )
        WeeklyCleanupRun.create!(family:, user:, period_start:, summary: report.summary)
      end
      created << chat
    end

    created
  end

  private
    attr_reader :family, :period_start

    # Admin-only by design: findings are family-wide and can name merchants,
    # categories, and amounts that members (or guests) must not see.
    # Deactivated users and admins with AI turned off don't get a chat.
    def admins
      family.users.select { |user| user.admin? && user.active? && user.ai_enabled? }
    end

    # Returns nil when any detector raised, so a partial scan is never
    # reported (or recorded) as a complete one.
    def collect_findings(user)
      failed = false
      findings = WeeklyCleanup::Detector.registry.filter_map do |detector_class|
        detector_class.new(family, user:).generate
      rescue => e
        failed = true
        Rails.logger.error("WeeklyCleanup: detector #{detector_class.key} failed for family #{family.id}: #{e.class}: #{e.message}")
        nil
      end
      failed ? nil : findings
    end
end
