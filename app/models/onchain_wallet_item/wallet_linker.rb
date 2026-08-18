# frozen_string_literal: true

# Creates the rows and accounts for the assets a user picked at an address.
#
# Metadata and quantities are re-read from the chain rather than taken from the
# form, so a tampered or stale selection can only ever change *which* assets are
# tracked, never what they claim to hold.
class OnchainWalletItem::WalletLinker
  Result = Data.define(:created, :errors) do
    def success?
      created.positive?
    end
  end

  attr_reader :onchain_wallet_item, :chain, :address

  def initialize(onchain_wallet_item, chain:, address:)
    @onchain_wallet_item = onchain_wallet_item
    @chain = chain
    @address = address
  end

  def link(snapshot:, selected_keys:)
    selected = Array(selected_keys).map(&:to_s).to_set
    created = 0
    errors = []

    snapshot.assets.each do |asset|
      next unless selected.include?(OnchainWalletItem::TokenReview.key_for(asset))

      begin
        create_asset!(asset)
        created += 1
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        errors << asset.symbol
        Rails.logger.warn("OnchainWalletItem::WalletLinker - could not link #{asset.symbol}: #{e.class}")
      end
    end

    onchain_wallet_item.sync_later if created.positive?

    Result.new(created: created, errors: errors)
  end

  private
    def create_asset!(asset)
      OnchainWalletAccount.transaction do
        onchain_account = onchain_wallet_item.onchain_wallet_accounts.create!(
          chain: chain,
          wallet_address: address,
          asset_kind: asset.kind,
          contract_address: asset.contract,
          symbol: asset.symbol,
          name: asset.name,
          decimals: asset.decimals,
          quantity: asset.quantity,
          currency: onchain_wallet_item.family.currency
        )

        account = Account.create_from_onchain_wallet_account(onchain_account)
        onchain_account.ensure_account_provider!(account)
      end
    end
end
