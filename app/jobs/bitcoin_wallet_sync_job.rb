# frozen_string_literal: true

class BitcoinWalletSyncJob < ApplicationJob
  queue_as :default
  discard_on BitcoinWalletAccount::Discovery::AddressMismatch, BitcoinWalletAccount::Discovery::Conflict
  retry_on BitcoinWalletAccount::Snapshot::ChangedTip, BitcoinWalletAccount::Snapshot::IncompleteMempool,
    Provider::MempoolSpace::Error, wait: :polynomially_longer, attempts: 3
  around_perform :with_wallet_timezone

  # Refresh a wallet unless its connection or account is pending deletion;
  # retries and invalid-source discards use the job's declared error policies.
  def perform(wallet)
    return if wallet.onchain_wallet_item.scheduled_for_deletion? || wallet.account.pending_deletion?

    wallet.sync_later
  end

  private
    # Apply the family's timezone to baseline dates and ledger movements for
    # the entire background read, falling back to the current zone if invalid.
    def with_wallet_timezone(&block)
      wallet = arguments.first
      zone = Time.find_zone(wallet.family.timezone) || Time.zone
      Time.use_zone(zone, &block)
    end
end
