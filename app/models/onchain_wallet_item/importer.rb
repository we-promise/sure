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
    @truncation_reported = Set.new
  end

  # @return [Hash] :wallets_imported, :changed_account_ids
  def import
    wallet_keys = onchain_wallet_item.wallet_keys
    changed_account_ids = []
    failures = []

    wallet_keys.each do |chain, address|
      changed_account_ids.concat(import_wallet(chain: chain, address: address))
    rescue Onchain::Chains::Error => e
      # One chain being unreachable is not a reason to leave the family's other
      # wallets unsynced. Recorded per address and carried on; only a wallet whose
      # every address failed is reported as a failed sync.
      failures << e
      report_unreachable(chain: chain, address: address, error: e)
    end

    raise failures.first if failures.any? && failures.size == wallet_keys.size

    {
      success: true,
      wallets_imported: wallet_keys.size - failures.size,
      wallets_failed: failures.size,
      changed_account_ids: changed_account_ids
    }
  end

  # Refreshes one address. Returns the ids of the rows whose on-chain state
  # changed, which is what the syncer reprocesses.
  def import_wallet(chain:, address:)
    snapshot = fetch_snapshot(chain: chain, address: address)

    onchain_wallet_item.accounts_for_wallet(chain, address).filter_map do |account|
      apply_snapshot(account, snapshot, chain: chain, address: address)
    end
  end

  # Reads an address without touching the database. Used by the linking and
  # token review flows to show the user what is there before anything is saved.
  def fetch_snapshot(chain:, address:)
    onchain_wallet_item.chain_adapter(chain).fetch_snapshot(address)
  end

  private
    def apply_snapshot(account, snapshot, chain:, address:)
      asset = snapshot.assets.find { |candidate| account.matches_asset?(candidate) }
      movements = asset ? relevant_movements(snapshot.movements_for(asset)) : []
      # An asset that vanished from the wallet is worth zero, not stale.
      quantity = normalize(asset&.quantity || 0)
      digest = content_hash(asset, quantity, movements)

      return nil if account.content_hash == digest

      report_truncation(chain: chain, address: address, snapshot: snapshot) if snapshot.history_truncated? || snapshot.assets_truncated?

      account.update!(
        quantity: quantity,
        symbol: asset&.symbol.presence || account.symbol,
        name: asset&.name.presence || account.name,
        decimals: asset&.decimals || account.decimals,
        content_hash: digest,
        raw_payload: asset_payload(asset),
        raw_movements_payload: { "movements" => movements.map { |movement| movement_payload(movement) } },
        # Recorded on the row so the UI can say the history is incomplete instead
        # of implying these movements are all there ever were.
        extra: account.extra.to_h.deep_merge(
          "onchain_wallet" => {
            "history_truncated" => snapshot.history_truncated?,
            "assets_truncated" => snapshot.assets_truncated?
          }
        )
      )

      account.id
    end

    def report_unreachable(chain:, address:, error:)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "On-chain address could not be read: #{error.class.name.demodulize}",
        source: self.class.name,
        provider_key: "onchain_wallet",
        family: onchain_wallet_item.family,
        metadata: { onchain_wallet_item_id: onchain_wallet_item.id, chain: chain, address: address }
      )
    end

    # A capped history is worth a support-visible note, but only once per address
    # per import, and only when something changed anyway — otherwise an idle
    # wallet with deep history would log the same line every night.
    def report_truncation(chain:, address:, snapshot:)
      return unless @truncation_reported.add?([ chain, address ])

      reasons = []
      reasons << "not every transfer was read" if snapshot.history_truncated?
      reasons << "not every token held is surfaced" if snapshot.assets_truncated?

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "On-chain read truncated: #{reasons.join("; ")}",
        source: self.class.name,
        provider_key: "onchain_wallet",
        family: onchain_wallet_item.family,
        metadata: {
          onchain_wallet_item_id: onchain_wallet_item.id,
          chain: chain,
          address: address,
          history_truncated: snapshot.history_truncated?,
          assets_truncated: snapshot.assets_truncated?,
          max_pages: Onchain::HistoryBudget.pages,
          max_tokens: Onchain::AssetBudget.tokens
        }
      )
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
    # Covers everything the update below writes. Leaving the metadata out meant a
    # Solana mint that later gained a real symbol from the token list produced the
    # same digest as before, so the row was never rewritten and its placeholder
    # label became permanent.
    def content_hash(asset, quantity, movements)
      payload = {
        "symbol" => asset&.symbol.to_s,
        "name" => asset&.name.to_s,
        "decimals" => asset&.decimals.to_s,
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

    # Postgres numeric happily stores NaN, and one NaN quantity would poison every
    # total that reads it, so a non-finite amount is treated as unknown rather
    # than written.
    def normalize(value)
      amount = BigDecimal(value.to_s)
      amount.finite? ? amount : 0.to_d
    rescue ArgumentError, TypeError
      0.to_d
    end
end
