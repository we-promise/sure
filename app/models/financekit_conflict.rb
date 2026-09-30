class FinancekitConflict < ApplicationRecord
  belongs_to :family
  belongs_to :financekit_item
  belongs_to :financekit_account_lineage, optional: true
  belongs_to :financekit_transaction, optional: true
  belongs_to :resolved_by, class_name: "User", optional: true

  scope :open, -> { where(status: "open") }

  def resolve!(user:, resolution:)
    Financekit.require!(%w[keep_sure retry_after_repair].include?(resolution), "invalid_resolution")
    financekit_item.with_lock do
      lock!
      Financekit.require!(status == "open", "conflict_already_resolved", 409)
      update!(status: "resolved", resolution: resolution, resolved_by: user, resolved_at: Time.current)
      if resolution == "retry_after_repair"
        release_conflicting_observation!
        financekit_item.mark_repair!("conflict_retry_requested")
      end
      # Both resolutions land on the same rule: a record is under review while
      # it still has an open conflict, whichever resolution closed this one.
      financekit_transaction&.refresh_review_required!
    end
  end

  private

    # Asking the publisher to retry only means something if the stored
    # observation stops blocking the replay. Observations are immutable, so the
    # same money would disagree again after the repair and the conflict would
    # simply reopen. Dropping the one the family declined lets the new
    # generation supply the value they chose to accept; every other observation
    # on the lineage is untouched, and the canonical balance still only moves
    # when a newer booked value lands.
    def release_conflicting_observation!
      return unless kind == "balance_observation_conflict" && financekit_account_lineage

      financekit_account_lineage.financekit_balance_observations
        .where(source_id: details["source_id"], kind: details["kind"],
          observed_at: details["observed_at"]).delete_all
    end
end
