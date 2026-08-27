# frozen_string_literal: true

# Writes one tracked asset into the account it is linked to: the holding, the
# account balance, and the entries that reconstruct how the position was built.
#
# Chain-agnostic by construction — it only ever reads the row and the payloads
# the importer stored on it.
class OnchainWalletAccount::Processor
  SOURCE = "onchain_wallet"
  # The label this processor writes on every movement. Named so the repair
  # below and the import above cannot drift apart.
  TRANSFER_LABEL = "Transfer"

  attr_reader :onchain_wallet_account

  def initialize(onchain_wallet_account)
    @onchain_wallet_account = onchain_wallet_account
  end

  def process
    return unless account

    security = resolve_security
    backfill_prices(security) if security
    price = security ? price_on(security, Date.current) : nil
    amount = price ? (quantity * price).round(4) : 0.to_d

    import_holding(security, price, amount) if security
    update_balances(amount)
    materialize_movements(security) if security
    report_zero_valuation(security) if security && price.nil?
  end

  # Converts movements that were recorded as display-only into trades, once a
  # price for their date exists.
  #
  # On a first sync the price history usually is not there yet, so transfers land
  # as zero-amount excluded entries. Nothing brought them back afterwards: the
  # syncer only reprocesses assets whose on-chain state changed, and an old
  # transfer never changes. The cost basis stayed broken for exactly the wallets
  # that were linked before market data caught up.
  #
  # Reads prices from the database only — no network — so this can run for every
  # linked asset on every sync.
  # @return [Integer] number of entries upgraded
  def repair_display_only_movements
    return 0 unless account

    relabelled = relabel_legacy_trades

    candidates = display_only_entries
    return relabelled if candidates.empty?

    security = resolve_security
    return relabelled if security.nil?

    relabelled + candidates.count { |entry| upgrade_to_trade(entry, security) }
  end

  private
    def account
      onchain_wallet_account.current_account
    end

    def currency
      onchain_wallet_account.currency.presence || account.currency
    end

    def quantity
      onchain_wallet_account.quantity.to_d
    end

    def resolve_security
      Onchain::SecurityResolver.resolve(
        symbol: onchain_wallet_account.symbol,
        name: onchain_wallet_account.name
      )
    end

    # A brand-new Security has no price history, so on a first sync every
    # movement would fall back to a display-only entry and the cost basis would
    # never reconstruct. One batched provider call covers the whole window
    # instead of one call per movement date. A no-op when no crypto price
    # provider is enabled — the settings panel warns about that up front.
    def backfill_prices(security)
      return if security.price_data_provider.blank?

      dates = movement_dates
      missing = dates.reject { |date| priced_dates(security, dates).include?(date) }
      return if missing.empty?

      security.import_provider_prices(start_date: missing.min, end_date: Date.current)
      security.prices.reload
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Could not backfill on-chain asset prices: #{e.class}",
        source: self.class.name,
        provider_key: "onchain_wallet",
        family: onchain_wallet_account.onchain_wallet_item.family,
        account: account,
        metadata: { security_id: security.id, ticker: security.ticker, error: e.message }
      )
    end

    # Today included, so a wallet whose movements all predate the sync window
    # still gets a current valuation.
    def movement_dates
      dates = movements.filter_map { |movement| parse_date(movement["date"]) }
      (dates + [ Date.current ]).uniq
    end

    def priced_dates(security, dates)
      @priced_dates ||= security.prices.where(date: dates.min..dates.max).pluck(:date).to_set
    end

    # The asset's price in the account's currency on (or most recently before)
    # a date, or nil when it isn't known. An asset with no price is tracked by
    # quantity and valued at zero rather than guessed at.
    def price_on(security, date)
      price = security.prices.where(date: ..date).order(date: :desc).first
      return nil if price.nil?

      convert(price.price.to_d, from: price.currency, date: date)
    end

    # Prices come from the crypto provider quoted in USD, so at most one
    # conversion stands between a price and the account currency.
    def convert(amount, from:, date:)
      return amount if from.to_s.upcase == currency.to_s.upcase

      rate = ExchangeRate.find_or_fetch_rate(from: from, to: currency, date: date)
      return nil if rate.nil?

      amount * rate.rate.to_d
    end

    # A holding that ends up worth zero because nothing can price crypto, or
    # because USD cannot be converted into the family's currency, is a
    # configuration problem rather than chain data. Users report it as a broken
    # sync, so the reason is recorded where support can see it — once per asset
    # per changed sync, and only for these causes: a price merely missing for
    # today is ordinary and already covered by the backfill.
    def report_zero_valuation(security)
      reasons = Onchain::Pricing.missing_for(currency)
      return if reasons.empty?

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "On-chain asset valued at zero: #{reasons.map { |reason| reason.to_s.humanize.downcase }.join(" and ")} not configured",
        source: self.class.name,
        provider_key: "onchain_wallet",
        family: onchain_wallet_account.onchain_wallet_item.family,
        account: account,
        metadata: {
          onchain_wallet_account_id: onchain_wallet_account.id,
          chain: onchain_wallet_account.chain,
          symbol: onchain_wallet_account.symbol,
          ticker: security.ticker,
          quantity: quantity.to_s("F"),
          currency: currency,
          reasons: reasons.map(&:to_s)
        }
      )
    end

    def import_holding(security, price, amount)
      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: currency,
        date: Date.current,
        # Holdings must carry a price; an unpriced asset is worth zero rather
        # than absent, so the quantity still shows up in the portfolio.
        price: price || 0,
        external_id: holding_external_id,
        account_provider_id: onchain_wallet_account.account_provider&.id,
        source: SOURCE
      )
    end

    def update_balances(amount)
      account.update!(balance: amount, cash_balance: 0, currency: currency)
      onchain_wallet_account.update!(current_balance: amount)
    end

    # Movements become one of two things:
    #   - a signed trade, when a price for that date is known, so cost basis and
    #     the value chart reconstruct back to acquisition;
    #   - otherwise a display-only, excluded entry with amount 0, so the transfer
    #     is still visible and its raw payload preserved, without inventing a
    #     value that would distort the account's history.
    def materialize_movements(security)
      movements.each do |movement|
        date = parse_date(movement["date"])
        next if date.nil?

        amount = parse_amount(movement["amount"])
        next if amount.nil? || amount.zero?

        price = exact_price_on(security, date)

        if price
          import_trade(security, movement, date, amount, price)
        else
          import_display_only_entry(movement, date, amount)
        end
      end
    end

    def import_trade(security, movement, date, quantity, price)
      write_trade(
        security: security,
        external_id: movement_external_id(movement),
        date: date,
        quantity: quantity,
        price: price
      )
    end

    # The one place a movement becomes a trade, used both on the way in and by the
    # repair pass.
    #
    # A movement first seen while its price was unknown already exists as a
    # display-only entry, and an Entry cannot change entryable type in place —
    # the shared importer refuses an external_id held by a Transaction. So the
    # display-only entry is discarded first and the trade takes over its
    # identity. Without this, every wallet linked before prices were available
    # raised on the first sync that could price it, which also meant the repair
    # pass — running after the sync — was never reached.
    def write_trade(security:, external_id:, date:, quantity:, price:)
      # One transaction, because the two halves are one change: if writing the
      # trade fails after the display-only entry is gone, the transfer would
      # vanish from the account until a later sync happened to rewrite it.
      Entry.transaction do
        discard_display_only_entry(external_id)

        import_adapter.import_trade(
          security: security,
          quantity: quantity,
          price: price,
          # Sure's convention for trades: money leaves the account on a buy.
          amount: -(quantity * price).round(4),
          currency: currency,
          date: date,
          # Named here because the shared helper says "Buy 0.5 shares of
          # CRYPTO:BTC" — "shares" is not a thing a wallet holds. The wording is
          # the same one an unpriced movement already carries, so a transfer
          # does not change its name the day a price turns up for it.
          name: movement_name(quantity),
          external_id: external_id,
          source: SOURCE,
          # A trade is the shape this ledger needs to carry quantity and cost
          # basis, but the event is a transfer: coins arriving at an address are
          # not a purchase, and nothing here knows whether they were ever bought.
          activity_label: TRANSFER_LABEL
        )
      end
    end

    def discard_display_only_entry(external_id)
      entry = account.entries.find_by(external_id: external_id, source: SOURCE)
      return if entry.nil? || !entry.entryable.is_a?(Transaction)

      entry.destroy!
    end

    def import_display_only_entry(movement, date, quantity)
      # Built directly rather than through the import adapter: this entry exists
      # only to be seen, so it must carry amount 0, excluded: true and the raw
      # movement, none of which the shared transaction importer models.
      entry = account.entries.find_or_initialize_by(
        external_id: movement_external_id(movement),
        source: SOURCE
      ) { |new_entry| new_entry.entryable = Transaction.new }

      return unless entry.entryable.is_a?(Transaction)

      entry.assign_attributes(
        date: date,
        amount: 0,
        currency: currency,
        name: movement_name(quantity),
        excluded: true
      )
      entry.entryable.extra = (entry.entryable.extra || {}).merge(SOURCE => movement)
      entry.save!
    end

    # The zero-amount, excluded entries this processor writes for unpriced
    # movements, identified by the external_id prefix it gave them.
    # Movements imported before transfers were called transfers still carry a
    # `Buy` or `Sell` label and a "Buy 0.5 shares of CRYPTO:BTC" name. Nothing
    # rewrites them on an ordinary sync: `perform_sync` returns early when no
    # address changed on chain, and the repair above only ever looked at
    # display-only `Transaction` rows. Left alone they would keep the old
    # wording for as long as the wallet sits still — which for a cold address
    # is the whole point of it.
    #
    # Scoped to this processor's own external_id prefix and to `source:
    # SOURCE`, so a trade the user entered by hand is never touched.
    def relabel_legacy_trades
      entries = account.entries
                       .where(source: SOURCE, entryable_type: "Trade")
                       .where("external_id LIKE ?", "#{holding_external_id}_%")
                       .includes(:entryable)
                       .to_a
      return 0 if entries.empty?

      entries.count do |entry|
        trade = entry.entryable
        expected_name = movement_name(trade.qty.to_d)
        next false if trade.investment_activity_label == TRANSFER_LABEL && entry.name == expected_name

        Entry.transaction do
          trade.update!(investment_activity_label: TRANSFER_LABEL)
          entry.update!(name: expected_name)
        end
        true
      end
    end

    def display_only_entries
      account.entries
        .where(source: SOURCE, entryable_type: "Transaction", excluded: true, amount: 0)
        .where("external_id LIKE ?", "#{holding_external_id}_%")
        .includes(:entryable)
        .to_a
    end

    def upgrade_to_trade(entry, security)
      movement = entry.entryable.extra.to_h[SOURCE].to_h
      amount = parse_amount(movement["amount"])
      return false if amount.nil? || amount.zero?

      price = exact_price_on(security, entry.date)
      return false if price.nil?

      Entry.transaction do
        write_trade(
          security: security,
          external_id: entry.external_id,
          date: entry.date,
          quantity: amount,
          price: price
        )
      end

      true
    end

    def movement_name(quantity)
      translated_name("onchain_wallet_item.movement.#{quantity.positive? ? "received" : "sent"}", quantity)
    end

    def translated_name(key, quantity)
      I18n.t(
        key,
        quantity: quantity.abs.round(8).to_s("F"),
        symbol: onchain_wallet_account.symbol
      )
    end

    def movements
      Array(onchain_wallet_account.raw_movements_payload&.dig("movements"))
    end

    # Trades need the price of that day, not the nearest one: valuing a
    # two-year-old transfer at today's price would invent a cost basis.
    def exact_price_on(security, date)
      price = security.prices.find_by(date: date)
      return nil if price.nil?

      convert(price.price.to_d, from: price.currency, date: date)
    end

    # Stored payloads are written by this code, but a row that survived an older
    # format should cost one movement rather than the whole asset's processing.
    #
    # NaN and the infinities have to be rejected explicitly: BigDecimal parses all
    # three, and neither is zero, so they would sail through into a trade and only
    # blow up on rounding.
    def parse_amount(value)
      amount = BigDecimal(value.to_s)
      amount.finite? ? amount : nil
    rescue ArgumentError, TypeError
      nil
    end

    def parse_date(value)
      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def holding_external_id
      "onchain_#{onchain_wallet_account.id}"
    end

    def movement_external_id(movement)
      "onchain_#{onchain_wallet_account.id}_#{movement["external_id"]}"
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end
end
