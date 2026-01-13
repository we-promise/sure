class SimplefinConnectionUpdateJob < ApplicationJob
  queue_as :high_priority

  # Disable automatic retries for this job since the setup token is single-use.
  # If the token claim succeeds but sync fails, retrying would fail at claim.
  discard_on Provider::Simplefin::SimplefinError do |job, error|
    Rails.logger.error(
      "SimplefinConnectionUpdateJob discarded: #{error.class} - #{error.message} " \
      "(family_id=#{job.arguments.first[:family_id]}, item_id=#{job.arguments.first[:old_simplefin_item_id]})"
    )
  end

  def perform(family_id:, old_simplefin_item_id:, setup_token:)
    family = Family.find(family_id)
    simplefin_item = family.simplefin_items.find(old_simplefin_item_id)

    # Step 1: Claim the new token and update the existing item's access_url.
    # This preserves all existing account linkages - no need to transfer anything.
    simplefin_item.update_access_url!(setup_token: setup_token)

    # Step 2: Sync the item to import fresh data.
    # The existing repair_stale_linkages logic handles cases where SimpleFIN
    # account IDs changed (e.g., user re-added institution in SimpleFIN Bridge).
    simplefin_item.sync_later

    Rails.logger.info(
      "SimplefinConnectionUpdateJob: Successfully updated SimplefinItem #{simplefin_item.id} " \
      "with new access_url for family #{family_id}"
    )
  end
end
