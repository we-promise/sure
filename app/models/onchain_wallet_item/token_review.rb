# frozen_string_literal: true

# The list of assets found at an address, for the user to choose from.
#
# Nothing is imported without being ticked. Real wallets are full of spam
# airdrops — and airdrops use plausible short symbols, so "the symbol looks like
# a ticker" pre-ticks nearly all of them. An asset is pre-ticked only when the
# data source also treats it as notable: a priced holding above dust on an EVM
# indexer, a place on Solana's verified token list. Everything else is listed,
# unchecked, and can still be tracked by quantity if the user wants it.
class OnchainWalletItem::TokenReview
  Row = Data.define(:asset, :key, :priceable, :tracked) do
    def preselected?
      tracked || (priceable && asset.notable?)
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
    @rows ||= (snapshot_rows + orphan_rows).sort_by { |row| [ row.native? ? 0 : 1, row.asset.symbol.to_s ] }
  end

  # Assets the user is already tracking that the chain no longer reports. They
  # stay listed so unticking them is still possible once they are gone.
  def orphan_accounts
    tracked_accounts.reject { |account| snapshot.assets.any? { |asset| account.matches_asset?(asset) } }
  end

  private
    def snapshot_rows
      snapshot.assets.map { |asset| row_for(asset) }
    end

    def orphan_rows
      orphan_accounts.map do |account|
        row_for(
          Onchain::Asset.new(
            kind: account.asset_kind,
            symbol: account.symbol,
            name: account.name,
            decimals: account.decimals,
            quantity: account.quantity,
            contract: account.contract_address
          )
        )
      end
    end

    def row_for(asset)
      key = self.class.key_for(asset)

      Row.new(
        asset: asset,
        key: key,
        priceable: Onchain::SecurityResolver.priceable?(asset.symbol),
        tracked: tracked_keys.include?(key)
      )
    end

    attr_reader :snapshot, :tracked_accounts

    def tracked_keys
      @tracked_keys ||= tracked_accounts.map(&:asset_key)
    end
end
