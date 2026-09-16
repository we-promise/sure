class SimplefinConnectionUpdateJob < ApplicationJob
  queue_as :high_priority
  self.log_arguments = false
  # Unexpected failures must remain visible without Sidekiq replaying a claim
  # that may already have consumed the setup token.
  sidekiq_options retry: false

  # Override ApplicationJob's deadlock retry: the claim may already have consumed
  # the token before saving credentials or scheduling the subsequent sync fails.
  # A failed/ambiguous claim requires reconciliation, not a whole-job replay.
  discard_on Provider::Simplefin::SimplefinError, ActiveRecord::Deadlocked do |job, error|
    Rails.logger.error(
      "SimplefinConnectionUpdateJob discarded: #{error.class} " \
      "(family_id=#{job.arguments.first[:family_id]}, claim_id=#{job.arguments.first[:claim_id]})"
    )
  end

  def perform(family_id:, claim_id: nil, old_simplefin_item_id: nil, setup_token: nil)
    if claim_id.blank? || old_simplefin_item_id || setup_token
      raise Provider::AccountData::LegacyWriterFence::OwnershipChanged,
        "SimpleFIN reconnect requires its original prepared claim"
    end
    SimplefinItem::ConnectionUpdate.perform(claim_id: claim_id, family_id: family_id)
  end
end
