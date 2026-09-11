# frozen_string_literal: true

# Creates the rows and accounts for the assets a user picked at an address.
#
# Metadata and quantities are re-read from the chain rather than taken from the
# form, so a tampered or stale selection can only ever change *which* assets are
# tracked, never what they claim to hold.
class OnchainWalletItem::WalletLinker
  Result = Data.define(:created, :removed, :errors) do
    def success?
      created.positive? || removed.positive?
    end

    def changed?
      created.positive? || removed.positive?
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

    # Reclaiming the address clears every row it left behind, not only the ones
    # matching what was picked now. An orphan row tracks nothing and yet shows
    # up in `grouped_accounts` and token review as though it did, so leaving
    # the unpicked ones behind trades one silent phantom for another — and
    # `revise` would then refuse to recreate the asset, because it would find
    # the orphan and take the asset for tracked.
    discard_orphan_rows

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

    Result.new(created: created, removed: 0, errors: errors)
  end

  # The same screen as linking, with the address left alone: ticking adds an
  # asset, unticking stops tracking it. Without this the only way to drop a
  # token would be to change the address, which is not the same thing.
  def revise(snapshot:, selected_keys:)
    selected = Array(selected_keys).map(&:to_s).to_set
    rows = onchain_wallet_item.accounts_for_wallet(chain, address).to_a
    errors = []

    removed = rows.count do |onchain_account|
      next false if selected.include?(onchain_account.asset_key)

      onchain_account.destroy!
      true
    end

    # Only a LINKED row means the asset is really tracked. A row left behind by
    # a deleted account has no Account and no AccountProvider, so counting it
    # here made ticking that asset a no-op: nothing created, the row still
    # orphaned, and the screen still reporting it as tracked. The rows just
    # destroyed above are out for the same reason.
    tracked = rows.reject(&:destroyed?).select { |row| row.account_provider.present? }

    created = snapshot.assets.count do |asset|
      next false unless selected.include?(OnchainWalletItem::TokenReview.key_for(asset))
      next false if tracked.any? { |onchain_account| onchain_account.matches_asset?(asset) }

      begin
        create_asset!(asset)
        true
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        errors << asset.symbol
        Rails.logger.warn("OnchainWalletItem::WalletLinker - could not link #{asset.symbol}: #{e.class}")
        false
      end
    end

    onchain_wallet_item.sync_later if created.positive?

    Result.new(created: created, removed: removed, errors: errors)
  end

  private
    # Every row at this address that no longer has an account behind it.
    def discard_orphan_rows
      onchain_wallet_item.onchain_wallet_accounts
        .for_wallet(chain, address)
        .unlinked
        .destroy_all
    end

    def discard_leftover_row(asset)
      onchain_wallet_item.onchain_wallet_accounts
        .for_wallet(chain, address)
        .unlinked
        .select { |row| row.matches_asset?(asset) }
        .each(&:destroy!)
    end

    def create_asset!(asset)
      OnchainWalletAccount.transaction do
        # A row left behind by a deleted account still holds this asset's slot in
        # the partial unique index while displaying nowhere, so creating beside
        # it raises. It tracks nothing, so it is the one that goes.
        discard_leftover_row(asset)

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
