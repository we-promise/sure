# Processes a Coinbase account to update balance and import trades.
# Updates the linked Account balance and creates Holdings records.
class CoinbaseAccount::Processor
  include CurrencyNormalizable

  # Maps Coinbase transaction types outside buy/sell to Sure's Trade
  # activity labels (see Trade::ACTIVITY_LABELS), so an account funded
  # mostly by staking rewards shows how its balance actually built up
  # over time instead of a single balance snapshot.
  #
  #   staking_reward                              -> Dividend   (income, paid in the held asset)
  #   interest                                    -> Interest   (exact match)
  #   pro_deposit/pro_withdrawal,
  #   staking_transfer/unstaking_transfer         -> Transfer   (moved between the user's own
  #                                                   Coinbase/Coinbase Pro/staking sub-accounts;
  #                                                   ownership preserved, no cost basis - see
  #                                                   Trade::TRANSFER_LABEL)
  #   exchange_deposit                            -> Transfer   (same asset, moved to another
  #                                                   exchange the user controls)
  #   asset_migration                             -> Exchange   (security-for-security swap,
  #                                                   e.g. a token rebrand)
  #   exchange_withdrawal                         -> Transfer   (same asset, moved to another
  #                                                   exchange the user controls - the withdrawal
  #                                                   side of exchange_deposit above)
  #   vault_withdrawal                            -> Transfer   (moved out of Coinbase Vault,
  #                                                   another of the user's own sub-accounts)
  #   send                                        -> Transfer   (could be a reward relabeled as
  #                                                   "send" - seen in real data - or a genuine
  #                                                   external transfer; no reliable way to tell
  #                                                   from the payload. "Other" would be worse:
  #                                                   Trade::INTERNAL_MOVEMENT_LABELS doesn't
  #                                                   include it, so #internal_movement? would
  #                                                   see a real buy/sell and let it fabricate a
  #                                                   cost-basis event from an ambiguous signal -
  #                                                   exactly what this whole map exists to avoid)
  #
  # Deliberately not handled: fiat_deposit/fiat_withdrawal move real cash, not
  # a crypto asset. CoinbaseAccount models a crypto wallet whose cash_balance
  # is always zero (see #process_account!), so a fiat movement needs a plain
  # cash Transaction entry on a different account, not a Trade here; that's
  # outside what this crypto-focused processor can represent today.
  ACTIVITY_LABEL_BY_COINBASE_TXN_TYPE = {
    "staking_reward" => "Dividend",
    "interest" => "Interest",
    "pro_deposit" => "Transfer",
    "pro_withdrawal" => "Transfer",
    "staking_transfer" => "Transfer",
    "unstaking_transfer" => "Transfer",
    "exchange_deposit" => "Transfer",
    "exchange_withdrawal" => "Transfer",
    "vault_withdrawal" => "Transfer",
    "asset_migration" => "Exchange",
    "send" => "Transfer"
  }.freeze

  # Dividend/Interest are real income paid in-kind rather than cash, but
  # InvestmentStatement::Totals reports dividends/interest as -SUM(entries.amount)
  # (see investment_statement/totals.rb) - zeroing amount for every label here
  # would make every imported staking reward look like $0 of income. Only the
  # Transfer/Exchange labels are genuinely cash-neutral (see amount: below).
  INCOME_LABELS = %w[Dividend Interest].freeze

  # Coinbase's transactions endpoint sometimes describes one real Pro/staking
  # transfer as two records in the same batch: a generic "send" plus a
  # specific pro_deposit/pro_withdrawal/etc with the same date+amount+currency.
  # Used by #shadowed_by_specific_transfer? to de-dupe those.
  SPECIFIC_TRANSFER_TYPES = %w[pro_deposit pro_withdrawal staking_transfer unstaking_transfer exchange_deposit].freeze

  attr_reader :coinbase_account

  # @param coinbase_account [CoinbaseAccount] Account to process
  def initialize(coinbase_account)
    @coinbase_account = coinbase_account
  end

  # Updates account balance and processes trades.
  # Skips processing if no linked account exists.
  def process
    unless coinbase_account.current_account.present?
      Rails.logger.info "CoinbaseAccount::Processor - No linked account for coinbase_account #{coinbase_account.id}, skipping processing"
      return
    end

    Rails.logger.info "CoinbaseAccount::Processor - Processing coinbase_account #{coinbase_account.id}"

    # Process holdings first to get the USD value
    begin
      process_holdings
    rescue StandardError => e
      Rails.logger.error "CoinbaseAccount::Processor - Failed to process holdings for #{coinbase_account.id}: #{e.message}"
      report_exception(e, "holdings")
      # Continue processing - balance update may still work
    end

    # Update account balance based on holdings value
    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "CoinbaseAccount::Processor - Failed to process account #{coinbase_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    # Process buy/sell transactions as trades
    process_trades
  end

  private

    # Creates/updates Holdings record for this crypto wallet.
    def process_holdings
      CoinbaseAccount::HoldingsProcessor.new(coinbase_account).process
    end

    # Updates the linked Account with current balance from Coinbase.
    # Balance is in the user's native currency (USD, EUR, GBP, etc.).
    def process_account!
      account = coinbase_account.current_account

      # Calculate balance from holdings value or native_balance
      native_value = calculate_native_balance

      Rails.logger.info(
        "CoinbaseAccount::Processor - Updating account #{account.id} balance: " \
        "#{native_value} #{native_currency} (#{coinbase_account.current_balance} #{coinbase_account.currency})"
      )

      account.update!(
        balance: native_value,
        cash_balance: 0, # Crypto accounts have no cash, all value is in holdings
        currency: native_currency
      )
    end

    # Calculates the value of this Coinbase wallet in the user's native currency.
    def calculate_native_balance
      # Primary source: Coinbase's native_balance if available
      native_amount = coinbase_account.raw_payload&.dig("native_balance", "amount")
      return native_amount.to_d if native_amount.present?

      # Try to calculate using spot price (always fetched in native currency pair)
      crypto_code = coinbase_account.currency
      quantity = (coinbase_account.current_balance || 0).to_d
      return 0 if quantity.zero?

      # Fetch spot price from Coinbase
      provider = coinbase_account.coinbase_item&.coinbase_provider
      if provider
        # Coinbase spot price API returns price in the pair's quote currency
        spot_data = provider.get_spot_price("#{crypto_code}-#{native_currency}")
        if spot_data && spot_data["amount"].present?
          price = spot_data["amount"].to_d
          native_value = (quantity * price).round(2)
          Rails.logger.info(
            "CoinbaseAccount::Processor - Calculated #{native_currency} value for #{crypto_code}: " \
            "#{quantity} * #{price} = #{native_value}"
          )
          return native_value
        end
      end

      # Fallback: Sum holdings values for this account
      account = coinbase_account.current_account
      if account.present?
        today_holdings = account.holdings.where(date: Date.current)
        if today_holdings.any?
          return today_holdings.sum(:amount)
        end
      end

      # Last resort: Return 0 if we can't calculate value
      Rails.logger.warn(
        "CoinbaseAccount::Processor - Could not calculate #{native_currency} value for #{crypto_code}, returning 0"
      )
      0
    end

    # Get native currency from Coinbase (USD, EUR, GBP, etc.)
    def native_currency
      @native_currency ||= coinbase_account.raw_payload&.dig("native_balance", "currency") ||
                           coinbase_account.current_account&.currency ||
                           "USD"
    end

    # Processes transactions (buys, sells, sends, receives) as trades.
    def process_trades
      return unless coinbase_account.raw_transactions_payload.present?

      # New format uses "transactions" array from /v2/accounts/{id}/transactions endpoint
      transactions = coinbase_account.raw_transactions_payload["transactions"] || []

      # Legacy format support (buys/sells arrays from deprecated endpoints)
      buys = coinbase_account.raw_transactions_payload["buys"] || []
      sells = coinbase_account.raw_transactions_payload["sells"] || []

      Rails.logger.info(
        "CoinbaseAccount::Processor - Processing #{transactions.count} transactions, " \
        "#{buys.count} legacy buys, #{sells.count} legacy sells"
      )

      # Process new format transactions
      transactions.each { |txn| process_transaction(txn) }

      # Process legacy format (for backwards compatibility)
      buys.each { |buy| process_legacy_buy(buy) }
      sells.each { |sell| process_legacy_sell(sell) }
    rescue StandardError => e
      report_exception(e, "trades")
    end

    # Process a transaction from the /v2/accounts/{id}/transactions endpoint.
    # Buy/sell go through the trade-specific path below; every other
    # completed type (staking_reward, interest, send, pro_deposit/withdrawal,
    # exchange_deposit, asset_migration, staking/unstaking_transfer) is
    # imported as a generic activity via #process_other_transaction_type
    # instead of being silently dropped.
    def process_transaction(txn_data)
      if %w[buy sell].include?(txn_data["type"])
        process_buy_sell_transaction(txn_data)
      else
        process_other_transaction_type(txn_data)
      end
    end

    # Handles every non-buy/sell completed transaction type using Coinbase's
    # own amount sign (positive = received into this wallet, negative = left
    # it - confirmed against real payloads for every type in
    # ACTIVITY_LABEL_BY_COINBASE_TXN_TYPE, no from/to parsing needed).
    def process_other_transaction_type(txn_data)
      return unless txn_data["status"] == "completed"

      account = coinbase_account.current_account
      return unless account

      txn_type = txn_data["type"]
      label = ACTIVITY_LABEL_BY_COINBASE_TXN_TYPE[txn_type]
      return unless label # unknown type - skip rather than guess

      raw_qty = txn_data.dig("amount", "amount").to_d
      return if raw_qty.zero?

      # Confirmed against real data: only a minority of "send" entries are
      # duplicates of a specific-type sibling (most are standalone, e.g. Earn
      # rewards tagged as "send") - so only skip a "send" when a specific-type
      # sibling actually matches it. Reconciling an already-imported duplicate
      # happens from the sibling's own side below, once it's confirmed saved -
      # never eagerly here: destroying the send before confirming the sibling
      # actually persists would leave the account with neither entry if the
      # sibling's own import then failed.
      return if txn_type == "send" && shadowed_by_specific_transfer?(txn_data)

      security = find_or_create_security(txn_data)
      return unless security

      external_id = "coinbase_txn_#{txn_data['id']}"
      if account.entries.exists?(external_id: external_id)
        reconcile_shadowed_sends(account, txn_data) if SPECIFIC_TRANSFER_TYPES.include?(txn_type)
        return
      end

      date = Time.zone.parse(txn_data["created_at"]).to_date
      qty = raw_qty.abs
      native_amount = txn_data.dig("native_amount", "amount").to_d.abs
      price = qty > 0 ? (native_amount / qty).round(8) : 0
      txn_currency = txn_data.dig("native_amount", "currency") || native_currency
      received = raw_qty.positive?

      # Transfer/Exchange move an asset the account already owns between its
      # own sub-ledgers (Trade::INTERNAL_MOVEMENT_LABELS) or swap it for an
      # equivalent one -- no real purchase or sale, so a real cash amount
      # would invent a cost basis backed by no actual cash, and since the two
      # legs of an internal transfer almost never share the same market
      # price, it'd also leave a phantom, permanent cash drift every time one
      # round-trips. Dividend/Interest is real income, just paid in-kind
      # instead of cash -- InvestmentStatement::Totals reports it as
      # -SUM(entries.amount), so zeroing it here would make every imported
      # staking reward look like $0 of income. Same sign convention as a Buy:
      # negative when received, since nothing here was paid for in cash.
      amount = INCOME_LABELS.include?(label) ? (received ? -native_amount : native_amount) : 0

      notes_parts = []
      notes_parts << txn_data["description"] if txn_data["description"].present?
      notes_parts << txn_type.humanize
      notes = notes_parts.join(" - ").presence

      account.entries.create!(
        date: date,
        name: "#{received ? "Received" : "Sent"} #{qty.round(8)} #{security.ticker} (#{txn_type.humanize})",
        amount: amount,
        currency: txn_currency,
        external_id: external_id,
        source: "coinbase",
        notes: notes,
        entryable: Trade.new(
          security: security,
          qty: received ? qty : -qty,
          price: price,
          currency: txn_currency,
          investment_activity_label: label
        )
      )
      Rails.logger.info(
        "CoinbaseAccount::Processor - Created #{txn_type} entry: #{raw_qty} #{security.ticker} @ #{price} #{txn_currency}"
      )
      reconcile_shadowed_sends(account, txn_data) if SPECIFIC_TRANSFER_TYPES.include?(txn_type)
    rescue => e
      Rails.logger.error "CoinbaseAccount::Processor - Failed to process #{txn_data['type']} transaction #{txn_data['id']}: #{e.message}"
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Failed to process #{txn_data['type']} transaction #{txn_data['id']}: #{e.message}",
        source: self.class.name,
        provider_key: "coinbase",
        family: coinbase_account.coinbase_item.family,
        account_provider: coinbase_account.account_provider,
        metadata: { coinbase_account_id: coinbase_account.id, coinbase_txn_id: txn_data["id"], txn_type: txn_data["type"] }
      )
    end

    # True when sibling_a and sibling_b describe the same date+amount+currency
    # leg - the shape Coinbase uses to double-log one real Pro/staking/vault
    # transfer as two records in the same batch (see SPECIFIC_TRANSFER_TYPES).
    # Matches on the *signed* amount, not its absolute value: both records
    # log the same leg with the same sign, so comparing magnitude alone would
    # also match an unrelated same-day transaction in the opposite direction
    # for the same amount and currency, confusing two independent events.
    def same_transfer_leg?(sibling_a, sibling_b)
      sibling_a["created_at"].to_s[0, 10] == sibling_b["created_at"].to_s[0, 10] &&
        sibling_a.dig("amount", "amount").to_d == sibling_b.dig("amount", "amount").to_d &&
        sibling_a.dig("amount", "currency") == sibling_b.dig("amount", "currency")
    end

    # True when txn_data (a "send") describes the same transfer as a
    # specific pro_deposit/pro_withdrawal/staking_transfer/etc sibling in the
    # same batch. A sibling still pending/failed/canceled can't shadow
    # anything either -- only a completed one actually happened.
    def shadowed_by_specific_transfer?(txn_data)
      siblings = coinbase_account.raw_transactions_payload&.dig("transactions") || []

      siblings.any? do |sibling|
        next false if sibling["id"] == txn_data["id"]
        next false unless SPECIFIC_TRANSFER_TYPES.include?(sibling["type"])
        next false unless sibling["status"] == "completed"
        same_transfer_leg?(sibling, txn_data)
      end
    end

    # The "send" siblings that txn_data (a specific-type transfer whose own
    # entry has just been confirmed saved, created or already existing)
    # shadows - the inverse of #shadowed_by_specific_transfer?, used once the
    # sibling side of the duplicate is itself confirmed, not from the send's
    # own processing.
    def shadowed_sends(txn_data)
      siblings = coinbase_account.raw_transactions_payload&.dig("transactions") || []

      siblings.select do |sibling|
        sibling["id"] != txn_data["id"] &&
          sibling["type"] == "send" &&
          sibling["status"] == "completed" &&
          same_transfer_leg?(sibling, txn_data)
      end
    end

    # Removes any previously-imported "send" entries now shadowed by
    # txn_data, a specific-transfer sibling whose own entry is confirmed
    # saved. Deferred to here rather than run eagerly from the send's own
    # processing: destroying a send before confirming its sibling actually
    # persists would leave the account with neither entry if the sibling's
    # own import then failed. A rate-limited partial fetch can import the
    # send before the sibling is ever reachable in the same batch; once a
    # later, more complete sync saves the sibling, leaving both would
    # double-count one real transfer as two entries.
    def reconcile_shadowed_sends(account, txn_data)
      shadowed_sends(txn_data).each do |send_txn|
        external_id = "coinbase_txn_#{send_txn['id']}"
        shadowed = account.entries.find_by(external_id: external_id)
        next unless shadowed
        # A user who excluded or edited this entry made a deliberate choice;
        # sync-driven reconciliation must not silently override it, same as
        # every other provider's sync code respects Entry#protected_from_sync?.
        next if shadowed.protected_from_sync?

        shadowed.destroy!
        Rails.logger.info(
          "CoinbaseAccount::Processor - Removed send #{send_txn['id']}, now shadowed by a specific transfer"
        )
      end
    end

    # Buy/sell transaction handling (trade with a cost-basis-relevant price).
    def process_buy_sell_transaction(txn_data)
      return unless txn_data["status"] == "completed"

      account = coinbase_account.current_account
      return unless account

      txn_type = txn_data["type"]

      # Get or create the security for this crypto
      security = find_or_create_security(txn_data)
      return unless security

      # Extract data from transaction (use Time.zone.parse for timezone safety)
      date = Time.zone.parse(txn_data["created_at"]).to_date
      qty = txn_data.dig("amount", "amount").to_d.abs
      native_amount = txn_data.dig("native_amount", "amount").to_d.abs

      # Get subtotal from buy/sell details if available (more accurate)
      if txn_type == "buy" && txn_data["buy"]
        subtotal = txn_data.dig("buy", "subtotal", "amount").to_d
        native_amount = subtotal if subtotal > 0
      elsif txn_type == "sell" && txn_data["sell"]
        subtotal = txn_data.dig("sell", "subtotal", "amount").to_d
        native_amount = subtotal if subtotal > 0
      end

      # Calculate price per unit (after subtotal override for accuracy)
      price = qty > 0 ? (native_amount / qty).round(8) : 0

      # Build notes from available Coinbase metadata
      notes_parts = []
      notes_parts << txn_data["description"] if txn_data["description"].present?
      notes_parts << txn_data.dig("details", "title") if txn_data.dig("details", "title").present?
      notes_parts << txn_data.dig("details", "subtitle") if txn_data.dig("details", "subtitle").present?
      # Add payment method info from buy/sell details
      payment_method = txn_data.dig(txn_type, "payment_method_name")
      notes_parts << I18n.t("coinbase.processor.paid_via", method: payment_method) if payment_method.present?
      notes = notes_parts.join(" - ").presence

      # Check if trade already exists by external_id
      external_id = "coinbase_txn_#{txn_data['id']}"
      existing = account.entries.find_by(external_id: external_id)
      if existing.present?
        # Update activity label if missing (fixes existing trades from before this was added)
        if existing.entryable.is_a?(Trade) && existing.entryable.investment_activity_label.blank?
          expected_label = txn_type == "buy" ? "Buy" : "Sell"
          existing.entryable.update!(investment_activity_label: expected_label)
          Rails.logger.info("CoinbaseAccount::Processor - Updated activity label to #{expected_label} for existing trade #{existing.id}")
        end
        return
      end

      # Get currency from native_amount or fall back to account's native currency
      txn_currency = txn_data.dig("native_amount", "currency") || native_currency

      # Create the trade
      if txn_type == "buy"
        # Buy: positive qty, money going out (negative amount)
        account.entries.create!(
          date: date,
          name: "Buy #{qty.round(8)} #{security.ticker}",
          amount: -native_amount,
          currency: txn_currency,
          external_id: external_id,
          source: "coinbase",
          notes: notes,
          entryable: Trade.new(
            security: security,
            qty: qty,
            price: price,
            currency: txn_currency,
            investment_activity_label: "Buy"
          )
        )
        Rails.logger.info("CoinbaseAccount::Processor - Created buy trade: #{qty} #{security.ticker} @ #{price} #{txn_currency}")
      else
        # Sell: negative qty, money coming in (positive amount)
        account.entries.create!(
          date: date,
          name: "Sell #{qty.round(8)} #{security.ticker}",
          amount: native_amount,
          currency: txn_currency,
          external_id: external_id,
          source: "coinbase",
          notes: notes,
          entryable: Trade.new(
            security: security,
            qty: -qty,
            price: price,
            currency: txn_currency,
            investment_activity_label: "Sell"
          )
        )
        Rails.logger.info("CoinbaseAccount::Processor - Created sell trade: #{qty} #{security.ticker} @ #{price} #{txn_currency}")
      end
    rescue => e
      Rails.logger.error "CoinbaseAccount::Processor - Failed to process transaction #{txn_data['id']}: #{e.message}"
    end

    # Legacy format processor for buy transactions (deprecated endpoint)
    def process_legacy_buy(buy_data)
      return unless buy_data["status"] == "completed"

      account = coinbase_account.current_account
      return unless account

      security = find_or_create_security(buy_data)
      return unless security

      date = Time.zone.parse(buy_data["created_at"]).to_date
      qty = buy_data.dig("amount", "amount").to_d
      price = buy_data.dig("unit_price", "amount").to_d
      total = buy_data.dig("total", "amount").to_d
      currency = buy_data.dig("total", "currency") || native_currency

      external_id = "coinbase_buy_#{buy_data['id']}"
      existing = account.entries.find_by(external_id: external_id)
      if existing.present?
        # Update activity label if missing
        if existing.entryable.is_a?(Trade) && existing.entryable.investment_activity_label.blank?
          existing.entryable.update!(investment_activity_label: "Buy")
        end
        return
      end

      account.entries.create!(
        date: date,
        name: "Buy #{security.ticker}",
        amount: -total,
        currency: currency,
        external_id: external_id,
        source: "coinbase",
        entryable: Trade.new(
          security: security,
          qty: qty,
          price: price,
          currency: currency,
          investment_activity_label: "Buy"
        )
      )
    rescue => e
      Rails.logger.error "CoinbaseAccount::Processor - Failed to process legacy buy: #{e.message}"
    end

    # Legacy format processor for sell transactions (deprecated endpoint)
    def process_legacy_sell(sell_data)
      return unless sell_data["status"] == "completed"

      account = coinbase_account.current_account
      return unless account

      security = find_or_create_security(sell_data)
      return unless security

      date = Time.zone.parse(sell_data["created_at"]).to_date
      qty = sell_data.dig("amount", "amount").to_d
      price = sell_data.dig("unit_price", "amount").to_d
      total = sell_data.dig("total", "amount").to_d
      currency = sell_data.dig("total", "currency") || native_currency

      external_id = "coinbase_sell_#{sell_data['id']}"
      existing = account.entries.find_by(external_id: external_id)
      if existing.present?
        # Update activity label if missing
        if existing.entryable.is_a?(Trade) && existing.entryable.investment_activity_label.blank?
          existing.entryable.update!(investment_activity_label: "Sell")
        end
        return
      end

      account.entries.create!(
        date: date,
        name: "Sell #{security.ticker}",
        amount: total,
        currency: currency,
        external_id: external_id,
        source: "coinbase",
        entryable: Trade.new(
          security: security,
          qty: -qty,
          price: price,
          currency: currency,
          investment_activity_label: "Sell"
        )
      )
    rescue => e
      Rails.logger.error "CoinbaseAccount::Processor - Failed to process legacy sell: #{e.message}"
    end

    def find_or_create_security(transaction_data)
      crypto_code = transaction_data.dig("amount", "currency")
      return nil unless crypto_code.present?

      # Use CRYPTO: prefix to distinguish from stock tickers
      ticker = crypto_code.include?(":") ? crypto_code : "CRYPTO:#{crypto_code}"

      # Try to resolve via Security::Resolver first
      begin
        Security::Resolver.new(ticker).resolve
      rescue => e
        Rails.logger.debug(
          "CoinbaseAccount::Processor - Resolver failed for #{ticker}: #{e.message}; creating offline security"
        )
        # Fall back to creating an offline security
        Security.find_or_create_by(ticker: ticker) do |security|
          security.name = transaction_data.dig("amount", "currency") || crypto_code
          security.exchange_operating_mic = "XCBS" # Coinbase exchange MIC
          security.offline = true if security.respond_to?(:offline=)
        end
      end
    end

    # Reports errors to Sentry with context tags.
    # @param error [Exception] The error to report
    # @param context [String] Processing context (e.g., "account", "trades")
    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          coinbase_account_id: coinbase_account.id,
          context: context
        )
      end
    end
end
