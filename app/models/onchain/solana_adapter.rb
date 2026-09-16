# frozen_string_literal: true

# Solana.
#
# Unlike an EVM chain, a Solana wallet does not hold its tokens: each SPL token
# sits in its own token account, owned by the wallet but addressed separately.
# So balances come from enumerating those accounts (both token programs), not
# from reading the wallet address, and several accounts can exist for one mint —
# they are summed. Emptied token accounts are left behind by design and are
# dropped here.
#
# RPC gives no token metadata, only mints, so names come from a keyless token
# list — and only for mints it reports as verified. Anyone can mint a token
# calling itself USDC, so an unverified or unknown mint keeps a label that
# deliberately cannot pass for a ticker: tracked by quantity, valued at zero,
# rather than handed an unrelated asset's price.
class Onchain::SolanaAdapter
  include Onchain::ChainAdapter

  LAMPORTS_PER_SOL = 1_000_000_000.to_d

  # Base58 (no 0, O, I or l). 32-byte keys encode to 43-44 characters, but
  # shorter encodings are legal, and Bitcoin's Base58 addresses fall inside this
  # range too — which is exactly why activity is probed rather than assumed.
  ADDRESS_PATTERN = /\A[1-9A-HJ-NP-Za-km-z]{32,44}\z/

  # Fallback for the handful of mints that must resolve even when the token list
  # is unreachable. Deliberately short: a wrong guess here would value a holding
  # as an unrelated asset.
  KNOWN_MINTS = {
    "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v" => { symbol: "USDC", name: "USD Coin" },
    "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB" => { symbol: "USDT", name: "Tether USD" },
    "2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo" => { symbol: "PYUSD", name: "PayPal USD" },
    "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263" => { symbol: "BONK", name: "Bonk" },
    "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN" => { symbol: "JUP", name: "Jupiter" },
    "jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL" => { symbol: "JTO", name: "Jito" }
  }.freeze

  # Each signature costs one getTransaction, so the transaction budget is what
  # bounds a sync on a rate-limited public endpoint. It comes from
  # Onchain::HistoryBudget so a self-hoster with their own node can raise it.
  SIGNATURES_PER_SOURCE = 25
  MAX_TOKEN_ACCOUNTS_FOR_HISTORY = 5

  # Below this, a native balance change is a transaction fee rather than a
  # transfer worth recording.
  FEE_DUST = BigDecimal("0.0001")

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    ADDRESS_PATTERN.match?(address.to_s.strip)
  end

  # One request. A Bitcoin address fits Solana's Base58 shape but is not a valid
  # 32-byte key, so the node rejects it and we answer "not here" — which is how
  # the linking flow tells the two apart.
  def has_activity?(address)
    return false unless valid_address?(address)

    return true if detection_provider.get_balance(address).positive?

    # A wallet can hold SPL tokens with no SOL of its own: each token account
    # carries its own rent, so an empty wallet address is not an empty wallet.
    # Only asked once the balance comes back zero, so the ordinary case still
    # costs the single request this probe is meant to be. Emptied token accounts
    # are left behind on Solana by design and are not activity.
    held_token_accounts(detection_provider.get_token_accounts(address)).any?
  rescue StandardError => e
    Rails.logger.warn("Onchain::SolanaAdapter - activity probe failed: #{e.class}")
    # Not false — see Onchain::ChainAdapter#has_activity? on the third answer.
    nil
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid Solana address" unless valid_address?(address)

    wrap_provider_errors do
      held = held_token_accounts(provider.get_token_accounts(address))
      token_accounts = surfaced_token_accounts(held)
      # Resolved once per snapshot, for every surfaced mint at once: assets and
      # movements must agree on what a token is called. Capping first bounds the
      # lookups too — an airdrop dump would otherwise cost dozens of requests.
      load_mint_metadata(token_accounts.map { |account| account[:mint] })

      movements = best_effort_movements { movements(address, token_accounts) }

      Onchain::Snapshot.new(
        assets: [ native_asset(address), *token_assets(token_accounts) ],
        movements: movements || [],
        history_truncated: movements.nil? || @history_truncated,
        assets_truncated: @assets_truncated
      )
    end
  end

  def provider_error_classes
    [ Provider::SolanaRpc::RateLimitError, Provider::SolanaRpc::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(Onchain::Chains::SOLANA)
    end

    def provider
      @provider ||= Provider::SolanaRpc.new
    end

    # Detection asks every candidate chain in turn on the request thread, so it
    # reads with the detection budget rather than the sync's: one short attempt,
    # no retry.
    def detection_provider
      @detection_provider ||= Provider::SolanaRpc.new(
        request_timeout: Onchain::DetectionBudget.timeout,
        max_retries: Onchain::DetectionBudget.retries
      )
    end

    def native_asset(address)
      definition.native_asset(quantity: provider.get_balance(address).to_d / LAMPORTS_PER_SOL)
    end

    # Emptied token accounts are left behind on Solana by design.
    def held_token_accounts(token_accounts)
      token_accounts.reject { |account| BigDecimal(account[:raw_amount].presence || "0").zero? }
    end

    # RPC offers no market signal to rank by, so the order is the mint itself:
    # arbitrary, but identical between two reads of an unchanged address, which is
    # what keeps the cap from reshuffling the wallet every sync.
    def surfaced_token_accounts(held)
      mints = held.map { |account| account[:mint] }.uniq.sort
      surfaced_mints = mints.first(Onchain::AssetBudget.tokens).to_set
      @assets_truncated = mints.size > surfaced_mints.size

      held.select { |account| surfaced_mints.include?(account[:mint]) }
    end

    # Summed per mint: one wallet can own several token accounts for the same
    # token, and they are one position.
    def token_assets(token_accounts)
      token_accounts.group_by { |account| account[:mint] }.filter_map do |mint, accounts|
        decimals = accounts.first[:decimals]
        quantity = accounts.sum { |account| BigDecimal(account[:raw_amount].presence || "0") } / (10.to_d**decimals)
        next if quantity.zero?

        metadata = mint_metadata(mint)
        definition.token_asset(
          symbol: metadata[:symbol],
          name: metadata[:name],
          decimals: decimals,
          quantity: quantity,
          contract: mint,
          # Only a mint the token list vouches for, or one we ship, is an asset
          # rather than an airdrop.
          notable: metadata[:verified] == true
        )
      end
    end

    # Verified metadata for every mint in one request, cached per mint. A token
    # list that is down or rate limiting is a naming inconvenience, not a sync
    # failure, so it degrades to the placeholder rather than raising.
    def load_mint_metadata(mints)
      unknown = mints.uniq.reject { |mint| KNOWN_MINTS.key?(mint) }
      @resolved_mints = unknown.any? ? token_list.metadata_for(unknown) : {}
    rescue StandardError => e
      Rails.logger.warn("Onchain::SolanaAdapter - token metadata unavailable: #{e.class}")
      @resolved_mints = {}
    end

    def token_list
      @token_list ||= Provider::JupiterTokens.new
    end

    # Falls back to a placeholder that cannot pass for a ticker, so security
    # resolution declines it instead of pricing an unrelated asset.
    def mint_metadata(mint)
      known = KNOWN_MINTS[mint] || @resolved_mints&.dig(mint)
      return known.merge(verified: true) if known

      { symbol: "SPL:#{mint.first(4)}…#{mint.last(4)}", name: "SPL token #{mint}", verified: false }
    end

    def movements(address, token_accounts)
      pages = signature_sources(address, token_accounts).map do |pubkey|
        provider.get_signatures(pubkey, limit: SIGNATURES_PER_SOURCE)
      end

      seen = pages.flatten
        .uniq { |entry| entry[:signature] }
        .sort_by { |entry| -entry[:block_time].to_i }

      # A source that fills its page has older signatures we never ask for: the
      # adapter passes no cursor, so a full page means the read stopped short of
      # the address's history rather than reaching the end of it. Counting only
      # the budget would call that history complete.
      capped_source = pages.any? { |page| page.size >= SIGNATURES_PER_SOURCE }

      budget = Onchain::HistoryBudget.transactions
      @history_truncated = capped_source || seen.size > budget
      signatures = seen.first(budget)

      signatures.flat_map do |entry|
        transaction = provider.get_transaction(entry[:signature])
        next [] if transaction.blank?

        movements_from(transaction, address, entry)
      rescue Provider::SolanaRpc::Error => e
        Rails.logger.warn("Onchain::SolanaAdapter - could not read #{entry[:signature]}: #{e.class}")
        []
      end
    end

    # The wallet's own history plus its largest token accounts: an SPL transfer
    # is signed against the token account, so the wallet address alone would miss
    # it.
    def signature_sources(address, token_accounts)
      largest = token_accounts
        .sort_by { |account| -BigDecimal(account[:raw_amount].presence || "0") }
        .first(MAX_TOKEN_ACCOUNTS_FOR_HISTORY)
        .filter_map { |account| account[:pubkey] }

      [ address, *largest ].uniq
    end

    def movements_from(transaction, address, signature_entry)
      meta = transaction["meta"].to_h
      return [] if meta["err"].present?

      timestamp = signature_time(transaction, signature_entry)
      return [] if timestamp.nil?

      signature = signature_entry[:signature]

      [
        native_movement(transaction, meta, address, signature, timestamp),
        *token_movements(meta, address, signature, timestamp)
      ].compact
    end

    def signature_time(transaction, signature_entry)
      block_time = signature_entry[:block_time] || transaction["blockTime"]
      return nil if block_time.blank?

      Time.zone.at(block_time.to_i)
    end

    def native_movement(transaction, meta, address, signature, timestamp)
      keys = Array(transaction.dig("transaction", "message", "accountKeys"))
      index = keys.index { |key| (key.is_a?(Hash) ? key["pubkey"] : key) == address }
      return nil if index.nil?

      pre = Array(meta["preBalances"])[index]
      post = Array(meta["postBalances"])[index]
      return nil if pre.nil? || post.nil?

      amount = (post.to_i - pre.to_i).to_d / LAMPORTS_PER_SOL
      return nil if amount.abs <= FEE_DUST

      Onchain::Movement.new(
        external_id: signature,
        symbol: definition.native.symbol,
        contract: nil,
        amount: amount,
        timestamp: timestamp
      )
    end

    def token_movements(meta, address, signature, timestamp)
      before = token_balances_by_mint(meta["preTokenBalances"], address)
      after = token_balances_by_mint(meta["postTokenBalances"], address)

      (before.keys | after.keys).filter_map do |mint|
        amount = after.fetch(mint, 0.to_d) - before.fetch(mint, 0.to_d)
        next if amount.zero?

        Onchain::Movement.new(
          external_id: "#{signature}_#{mint}",
          symbol: mint_metadata(mint)[:symbol],
          contract: mint,
          amount: amount,
          timestamp: timestamp
        )
      end
    end

    def token_balances_by_mint(balances, address)
      Array(balances).each_with_object({}) do |balance, totals|
        next unless balance["owner"] == address

        mint = balance["mint"].to_s
        amount = balance.dig("uiTokenAmount", "amount")
        decimals = balance.dig("uiTokenAmount", "decimals").to_i
        next if mint.blank? || amount.blank?

        totals[mint] = totals.fetch(mint, 0.to_d) + (BigDecimal(amount.to_s) / (10.to_d**decimals))
      end
    rescue ArgumentError
      {}
    end
end
