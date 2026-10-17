# frozen_string_literal: true

# Processes a Wise balance that was linked to a Sure account while its
# connection was already syncing. That sync picked the accounts it processes
# before the link existed, and WiseItem#sync_later only reuses a sync in
# flight, so without this the new account stayed empty until the next sync.
class WiseItem::ProcessLinkedAccountJob < ApplicationJob
  queue_as :high_priority

  def perform(wise_account)
    account = wise_account.current_account
    return unless processable?(wise_account, account)

    # Processing holds the balance's processing lock (WiseAccount
    # #with_processing_lock), so it does not interleave with the connection's
    # sync processing the same balance, and its rows commit one by one: no
    # transaction spans the payload, which would keep the next link click
    # and every other account save of the owner waiting until it ends. The
    # stored payload is booked as a sync books it, but nothing is deleted:
    # only the sync that imported the payload knows whether it is complete.
    WiseAccount::Processor.new(wise_account, import_complete: false).process
    # Once the new legs are committed, and before the account sync's
    # transfer matching sees them.
    wise_account.wise_item.link_jar_transfers!

    account.sync_later
  rescue ActiveRecord::Deadlocked
    raise # retried (ApplicationJob)
  rescue => e
    # The next sync processes the balance anyway, so this is logged rather
    # than retried.
    Rails.logger.error("#{self.class.name} - Failed to process wise_account #{wise_account.id}: #{e.class} - #{e.message}")
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "#{self.class.name} - Failed to process a newly linked Wise balance",
      source: self.class.name,
      provider_key: "wise",
      family: wise_account.wise_item&.family,
      account_provider: wise_account.account_provider,
      metadata: { wise_item_id: wise_account.wise_item_id, wise_account_id: wise_account.id, error_class: e.class.name }
    )
  end

  private

    # The balances WiseItem#process_accounts would process.
    def processable?(wise_account, account)
      account.present? &&
        Account::VISIBLE_STATUSES.include?(account.status) &&
        !wise_account.wise_item.scheduled_for_deletion?
    end
end
