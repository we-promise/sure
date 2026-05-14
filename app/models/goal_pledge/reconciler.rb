class GoalPledge::Reconciler
  attr_reader :entry

  def initialize(entry)
    @entry = entry
  end

  def run
    return unless eligible_entry?
    return if already_stamped?

    GoalPledge
      .where(account_id: entry.account_id, status: "open", kind: expected_kind)
      .where("expires_at >= ?", Time.current)
      .find_each do |pledge|
      next unless pledge.matches?(entry)

      begin
        pledge.resolve_with!(entry.transaction) if entry.entryable.is_a?(Transaction)
        pledge.update!(status: "matched") if entry.entryable.is_a?(Valuation)
        Rails.logger.info("GoalPledge ##{pledge.id} matched entry ##{entry.id}")
        return
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("GoalPledge ##{pledge.id} match failed: #{e.message}")
      end
    end
  rescue StandardError => e
    Rails.logger.error("GoalPledge::Reconciler failed for entry ##{entry&.id}: #{e.class}: #{e.message}")
  end

  private
    def eligible_entry?
      return false if entry.account_id.blank?
      return false if entry.excluded?

      entry.entryable.is_a?(Transaction) || entry.entryable.is_a?(Valuation)
    end

    def already_stamped?
      return false unless entry.entryable.is_a?(Transaction)

      entry.transaction.extra.dig("goal", "pledge_id").present?
    end

    def expected_kind
      entry.entryable.is_a?(Valuation) ? "manual_save" : "transfer"
    end
end
