# frozen_string_literal: true

# The list of assets found at an address, for the user to choose from.
#
# Nothing is imported without being ticked. Real wallets are full of spam
# airdrops, so only assets whose symbol a price provider can quote are
# pre-checked; the rest are listed, unchecked, and can still be tracked by
# quantity if the user wants them.
class OnchainWalletItem::TokenReview
  Row = Data.define(:asset, :key, :priceable, :tracked) do
    def preselected?
      tracked || priceable
    end

    def native?
      asset.native?
    end
  end

  # Identifies an asset across the request boundary without trusting the client
  # for anything else: the quantities and metadata are re-read from the chain
  # when the selection is applied.
  def self.key_for(asset)
    [ asset.kind, asset.contract_key ].compact.join(":")
  end

  def initialize(snapshot:, tracked_accounts: [])
    @snapshot = snapshot
    @tracked_accounts = tracked_accounts
  end

  def rows
    @rows ||= snapshot.assets.map do |asset|
      Row.new(
        asset: asset,
        key: self.class.key_for(asset),
        priceable: Onchain::SecurityResolver.priceable?(asset.symbol),
        tracked: tracked_keys.include?(self.class.key_for(asset))
      )
    end.sort_by { |row| [ row.native? ? 0 : 1, row.asset.symbol.to_s ] }
  end

  # Assets the user is already tracking that the chain no longer reports. They
  # stay listed so unticking them is possible even once they are gone.
  def orphan_accounts
    tracked_accounts.reject { |account| snapshot.assets.any? { |asset| account.matches_asset?(asset) } }
  end

  private
    attr_reader :snapshot, :tracked_accounts

    def tracked_keys
      @tracked_keys ||= tracked_accounts.map do |account|
        [ account.asset_kind, account.contract_address.presence ].compact.join(":")
      end
    end
end
