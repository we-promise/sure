# Re-signs a Sophtron account's stored transactions after its detected sign
# convention changes, then recalculates the linked account's balances.
#
# Runs outside the request that saved the override because it re-imports every
# stored transaction, and it does not wait for an item sync, which skips cards
# marked for manual sync. Re-signing is idempotent, so a retry starts over.
class SophtronTransactionsReprocessJob < ApplicationJob
  class IncompleteReprocess < StandardError; end
  class AccountSyncInProgress < StandardError; end

  queue_as :medium_priority

  # A transaction that failed to save keeps its old sign, and no other sync
  # retries it for a manual-sync card.
  retry_on IncompleteReprocess, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.record_failure(error)
    job.account&.sync_later
  end

  # A running sync may have read the amounts before they were re-signed, and
  # sync_later would join it rather than start a fresh calculation.
  retry_on AccountSyncInProgress, wait: 30.seconds, attempts: 20 do |job, _error|
    job.account&.sync_later
  end

  def perform(sophtron_account)
    @sophtron_account = sophtron_account
    return unless account.present?

    result = SophtronAccount::Transactions::Processor.new(sophtron_account).process
    unless result[:success]
      raise IncompleteReprocess, "#{result[:failed]} of #{result[:total]} Sophtron transactions could not be re-signed"
    end

    raise AccountSyncInProgress if account.syncs.visible.where(status: "syncing").exists?

    account.sync_later
  end

  def account
    sophtron_account&.current_account
  end

  def record_failure(error)
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Failed to re-sign Sophtron transactions after a sign convention change",
      source: self.class.name,
      provider_key: "sophtron",
      family: account&.family,
      account: account,
      account_provider: sophtron_account&.account_provider,
      metadata: { error_class: error.class.name, error_message: error.message }
    )
  end

  private
    def sophtron_account
      @sophtron_account ||= arguments.first
    end
end
