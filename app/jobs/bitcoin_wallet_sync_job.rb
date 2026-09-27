# frozen_string_literal: true

class BitcoinWalletSyncJob < ApplicationJob
  queue_as :default
  discard_on BitcoinWalletAccount::Discovery::AddressMismatch, BitcoinWalletAccount::Discovery::Conflict
  retry_on BitcoinWalletAccount::Snapshot::ChangedTip, BitcoinWalletAccount::Snapshot::IncompleteMempool,
    Provider::MempoolSpace::Error, wait: :polynomially_longer, attempts: 3
  around_perform :with_wallet_timezone

  def perform(wallet)
    return if wallet.onchain_wallet_item.scheduled_for_deletion? || wallet.account.pending_deletion?

    BitcoinWalletAccount::Syncer.new(wallet).perform
  end

  private
    def with_wallet_timezone(&block)
      wallet = arguments.first
      zone = Time.find_zone(wallet.family.timezone) || Time.zone
      Time.use_zone(zone, &block)
    end
end
