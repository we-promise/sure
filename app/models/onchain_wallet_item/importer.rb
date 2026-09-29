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
      attributes = if asset.nil? && snapshot.assets_truncated?
        # The read was capped before it reached this asset, so its absence says
        # nothing: we did not learn that it holds nothing, we failed to look.
        # Zeroing it here would take a real balance off the user's net worth —
        # the same distinction already made for an address we could not read.
        last_known_attributes(account, snapshot)
      else
        observed_attributes(account, snapshot, asset)
      end

      # The digest is taken from exactly what is about to be written, so the two
      # cannot drift apart. Deriving it from a hand-picked subset is how the symbol
      # was left out once — a Solana placeholder that gained a real name produced
      # the old digest and was never rewritten — and then the truncation flags,
      # leaving the UI claiming an incomplete history after one became complete.
      digest = Digest::SHA256.hexdigest(canonical(attributes).to_json)

      return nil if account.content_hash == digest

      report_truncation(chain: chain, address: address, snapshot: snapshot) if snapshot.history_truncated? || snapshot.assets_truncated?

      account.update!(attributes.merge(content_hash: digest))

      account.id
    end

    # Key order carries no information, and jsonb does not preserve it: an `extra`
    # written as {history, assets} comes back as {assets, history}, which would make
    # the digest of an unchanged wallet flip every other sync. Numbers are compared
    # by value rather than by representation for the same reason.
    def canonical(value)
      case value
      when Hash then value.map { |key, nested| [ key.to_s, canonical(nested) ] }.sort_by(&:first).to_h
      when Array then value.map { |entry| canonical(entry) }
      when BigDecimal then value.to_s("F")
      else value
      end
    end

    # What the chain just said about this asset. An asset genuinely gone from a
    # complete read is worth zero, not stale.
    def observed_attributes(account, snapshot, asset)
      # Sorted so that two reads of the same state produce the same payload, and
      # therefore the same digest, whatever order the source listed them in.
      movements = asset ? relevant_movements(snapshot.movements_for(asset)).sort_by { |movement| [ movement.date.to_s, movement.external_id.to_s ] } : []

      {
        quantity: normalize(asset&.quantity || 0),
        symbol: asset&.symbol.presence || account.symbol,
        name: asset&.name.presence || account.name,
        decimals: asset&.decimals || account.decimals,
        raw_payload: asset_payload(asset),
        raw_movements_payload: { "movements" => movements.map { |movement| movement_payload(movement) } },
        extra: truncation_extra(account, snapshot)
      }
    end

    # Everything the row already holds, with only the completeness flags refreshed.
    def last_known_attributes(account, snapshot)
      {
        quantity: account.quantity,
        symbol: account.symbol,
        name: account.name,
        decimals: account.decimals,
        raw_payload: account.raw_payload,
        raw_movements_payload: account.raw_movements_payload,
        extra: truncation_extra(account, snapshot)
      }
    end

    # Recorded on the row so the UI can say the read was incomplete instead of
    # implying what it returned is all there is.
    def truncation_extra(account, snapshot)
      account.extra.to_h.deep_merge(
        "onchain_wallet" => {
          "history_truncated" => snapshot.history_truncated?,
          "assets_truncated" => snapshot.assets_truncated?
        }
      )
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
