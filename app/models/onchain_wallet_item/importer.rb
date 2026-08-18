# frozen_string_literal: true

# Turns what the chains say into rows on onchain_wallet_accounts.
#
# The importer consumes Onchain::Snapshots and knows nothing about any chain:
# it asks the registry for an adapter, matches the assets it gets back against
# the rows the user chose to track, and records a digest of that state so the
# syncer can tell whether anything actually moved.
#
# It deliberately never creates rows. Real wallets are full of spam airdrops, so
# a newly seen token becomes trackable only when the user ticks it in the token
# review screen.
class OnchainWalletItem::Importer
  attr_reader :onchain_wallet_item

  def initialize(onchain_wallet_item)
    @onchain_wallet_item = onchain_wallet_item
  end

  # @return [Hash] :wallets_imported, :changed_account_ids
  def import
    wallet_keys = onchain_wallet_item.wallet_keys
    changed_account_ids = []

    wallet_keys.each do |chain, address|
      changed_account_ids.concat(import_wallet(chain: chain, address: address))
    end

    { success: true, wallets_imported: wallet_keys.size, changed_account_ids: changed_account_ids }
  end

  # Refreshes one address. Returns the ids of the rows whose on-chain state
  # changed, which is what the syncer reprocesses.
  def import_wallet(chain:, address:)
    snapshot = fetch_snapshot(chain: chain, address: address)

    onchain_wallet_item.accounts_for_wallet(chain, address).filter_map do |account|
      apply_snapshot(account, snapshot)
    end
  end

  # Reads an address without touching the database. Used by the linking and
  # token review flows to show the user what is there before anything is saved.
  def fetch_snapshot(chain:, address:)
    onchain_wallet_item.chain_adapter(chain).fetch_snapshot(address)
  end

  private
    def apply_snapshot(account, snapshot)
      asset = snapshot.assets.find { |candidate| account.matches_asset?(candidate) }
      movements = asset ? relevant_movements(snapshot.movements_for(asset)) : []
      # An asset that vanished from the wallet is worth zero, not stale.
      quantity = normalize(asset&.quantity || 0)
      digest = content_hash(quantity, movements)

      return nil if account.content_hash == digest

      account.update!(
        quantity: quantity,
        symbol: asset&.symbol.presence || account.symbol,
        name: asset&.name.presence || account.name,
        decimals: asset&.decimals || account.decimals,
        content_hash: digest,
        raw_payload: asset_payload(asset),
        raw_movements_payload: { "movements" => movements.map { |movement| movement_payload(movement) } }
      )

      account.id
    end

    # Movements before the connection's start date are outside the window the
    # user asked us to reconstruct.
    def relevant_movements(movements)
      start_date = onchain_wallet_item.sync_start_date&.to_date
      movements = movements.reject { |movement| movement.date.nil? }
      return movements if start_date.nil?

      movements.select { |movement| movement.date >= start_date }
    end

    # Digest of everything that would change what we write downstream. No
    # timestamps: two identical reads of an idle wallet must produce the same
    # digest so the syncer can skip it.
    def content_hash(quantity, movements)
      payload = {
        "quantity" => quantity.to_s("F"),
        "movements" => movements
          .map { |movement| [ movement.external_id.to_s, normalize(movement.amount).to_s("F"), movement.date.to_s ] }
          .sort
      }

      Digest::SHA256.hexdigest(payload.to_json)
    end

    def asset_payload(asset)
      return {} if asset.nil?

      {
        "kind" => asset.kind,
        "symbol" => asset.symbol,
        "name" => asset.name,
        "decimals" => asset.decimals,
        "contract" => asset.contract_key,
        "quantity" => normalize(asset.quantity).to_s("F")
      }
    end

    def movement_payload(movement)
      {
        "external_id" => movement.external_id,
        "symbol" => movement.symbol,
        "contract" => movement.contract_key,
        "amount" => normalize(movement.amount).to_s("F"),
        "date" => movement.date.to_s
      }
    end

    def normalize(value)
      BigDecimal(value.to_s)
    end
end
