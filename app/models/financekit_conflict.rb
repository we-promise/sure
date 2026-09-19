class FinancekitConflict < ApplicationRecord
  belongs_to :family
  belongs_to :financekit_item
  belongs_to :financekit_account_lineage, optional: true
  belongs_to :financekit_transaction, optional: true
  belongs_to :resolved_by, class_name: "User", optional: true

  scope :open, -> { where(status: "open") }

  def resolve!(user:, resolution:)
    Financekit.require!(status == "open", "conflict_already_resolved", 409)
    Financekit.require!(%w[keep_sure retry_after_repair].include?(resolution), "invalid_resolution")
    transaction do
      update!(status: "resolved", resolution: resolution, resolved_by: user, resolved_at: Time.current)
      case resolution
      when "keep_sure"
        financekit_transaction&.update!(review_required: false)
      when "retry_after_repair"
        financekit_item.mark_repair!("conflict_retry_requested")
      end
    end
  end
end
