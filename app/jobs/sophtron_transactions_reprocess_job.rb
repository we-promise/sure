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

  SYNC_WAIT = 30.seconds

  # A transaction that failed to save keeps its old sign, and no other sync
  # retries it for a manual-sync card. Once retries run out, the transactions
  # that were re-signed still get a fresh calculation, behind the same guard.
  retry_on IncompleteReprocess, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.record_failure(error, "Failed to re-sign Sophtron transactions after a sign convention change")
    job.class.perform_later(job.arguments.first, reprocess: false)
  end

  # A running sync may have read the amounts before they were re-signed, and
  # sync_later would join it rather than start a fresh calculation. sync_later
  # only joins a sync for Sync::VISIBLE_FOR after it was created, so these
  # retries outlast the guard, and running out of them means something else
  # is wrong; it is logged rather than joined.
  retry_on AccountSyncInProgress, wait: SYNC_WAIT, attempts: (Sync::VISIBLE_FOR / SYNC_WAIT).ceil + 2 do |job, error|
    job.record_failure(error, "Gave up waiting for a running sync after re-signing Sophtron transactions")
  end

  def perform(sophtron_account, reprocess: true)
    @sophtron_account = sophtron_account
    return unless account.present?

    if reprocess
      result = SophtronAccount::Transactions::Processor.new(sophtron_account).process
      unless result[:success]
        raise IncompleteReprocess, "#{result[:failed]} of #{result[:total]} Sophtron transactions could not be re-signed"
      end
    end

    raise AccountSyncInProgress if account.syncs.visible.where(status: "syncing").exists?

    account.sync_later
  end

  def account
    sophtron_account&.current_account
  end

  def record_failure(error, message)
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: message,
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
