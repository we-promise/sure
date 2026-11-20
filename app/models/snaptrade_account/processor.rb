class SnaptradeAccount::Processor
  include SnaptradeAccount::DataHelpers

  attr_reader :snaptrade_account

  def initialize(snaptrade_account)
    @snaptrade_account = snaptrade_account
  end

  def process
    account = snaptrade_account.current_account
    return unless account

    Rails.logger.info "SnaptradeAccount::Processor - Processing account #{snaptrade_account.id} -> Sure account #{account.id}"

    # Capture the reading's date before the import can cross midnight.
    date = Date.current

    anchor_balance = update_account_balance(account)

    # Process holdings
    holdings_count = snaptrade_account.raw_holdings_payload&.size || 0
    Rails.logger.info "SnaptradeAccount::Processor - Holdings payload has #{holdings_count} items"

    # Always run: an empty payload can clear sold positions, and non-primary
    # cash is surfaced as synthetic cash holdings (#1809).
    SnaptradeAccount::HoldingsProcessor.new(snaptrade_account).process

    # Process activities (trades, dividends, etc.)
    activities_count = snaptrade_account.raw_activities_payload&.size || 0
    Rails.logger.info "SnaptradeAccount::Processor - Activities payload has #{activities_count} items"

    activities_ok = true
    if snaptrade_account.raw_activities_payload.present?
      Rails.logger.info "SnaptradeAccount::Processor - Processing activities..."
      activities = SnaptradeAccount::ActivitiesProcessor.new(snaptrade_account).process
      activities_ok = activities[:failed].zero?
    else
      Rails.logger.warn "SnaptradeAccount::Processor - No activities payload to process"
    end

    if anchor_balance
      correct_pre_sign_fix_anchor(account, anchor_balance, date)
      account.set_current_balance(
        anchor_balance,
        date: date,
        reuse_explained_anchor: activities_ok
      )
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    # This is critical for fresh account links where the sync complete broadcast
    # might be delayed by child syncs (balance calculations)
    account.broadcast_sync_complete
    Rails.logger.info "SnaptradeAccount::Processor - Broadcast sync complete for account #{account.id}"

    { holdings_processed: holdings_count > 0, activities_processed: activities_count > 0 }
  end

  private

    # Syncs before liability balances were negated stored a card's reading as
    # SnapTrade sends it, owed as negative. Left alone, that anchor is kept as a
    # past reconciliation beside the first positive one, and the card's history
    # shows a jump that never happened. A card in credit reads negative now too,
    # so a negative anchor is only turned around when the reading less what was
    # imported since says the card owed money on the anchor's date. That holds
    # for a stale anchor even with flows missing, and for a card that went from
    # credit to owing it doesn't.
    def correct_pre_sign_fix_anchor(account, balance, date)
      return unless account.liability? && balance.positive?

      manager = Account::CurrentBalanceManager.new(account)
      anchor = manager.current_anchor_entry
      return unless anchor&.amount&.negative?

      net = manager.ledger_net_since(anchor, date)
      return if net.nil? || balance - net <= 0

      # Leaves updated_at alone: it marks which flows the reading had seen.
      anchor.update_columns(amount: -anchor.amount)
    end

    def update_account_balance(account)
      # Calculate total balance and cash balance from SnapTrade data
      total_balance = calculate_total_balance
      cash_balance = calculate_cash_balance

      # SnapTrade reports a card's debt as a negative balance; Sure stores what's
      # owed on a liability as a positive one.
      if account.liability?
        total_balance = -total_balance
        cash_balance = -cash_balance
      end

      Rails.logger.debug "SnaptradeAccount::Processor - Balance update: total=#{total_balance}, cash=#{cash_balance}"

      # Update the cached fields on the account
      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: snaptrade_account.currency || account.currency
      )
      account.save!

      total_balance
    end

    def calculate_total_balance
      if use_api_total_balance?
        Rails.logger.debug "SnaptradeAccount::Processor - Using API total for multi-currency holdings for snaptrade_account=#{snaptrade_account.id}"
        return snaptrade_account.current_balance || 0
      end

      # Calculate total from holdings + cash for accuracy
      # SnapTrade's current_balance can sometimes be stale or just the cash value
      holdings_value = calculate_holdings_value
      cash_value = calculate_cash_balance

      calculated_total = holdings_value + cash_value

      # Use calculated total if we have holdings, otherwise trust API value.
      # Net short positions (a short option on its own) make it negative; then
      # only when nothing is missing from it: a long without units or a price
      # counts as 0 and would leave just the short.
      if holdings_value.positive? || (holdings_value.negative? && net_short_total_complete?)
        Rails.logger.debug "SnaptradeAccount::Processor - Using calculated total: holdings=#{holdings_value} + cash=#{cash_value} = #{calculated_total}"
        calculated_total
      elsif snaptrade_account.current_balance.present?
        Rails.logger.debug "SnaptradeAccount::Processor - Using API total: #{snaptrade_account.current_balance}"
        snaptrade_account.current_balance
      else
        calculated_total
      end
    end

    def calculate_cash_balance
      # Memoized: called for both the total and the cash figure, and the
      # cash-equivalent exclusion should only be recorded once per sync.
      @calculate_cash_balance ||= begin
        # Note: Can be negative for margin accounts
        cash = snaptrade_account.cash_balance
        Rails.logger.debug "SnaptradeAccount::Processor - Cash balance from API: #{cash.inspect}"

        if cash.nil?
          BigDecimal("0")
        else
          # SnapTrade includes money market / sweep funds (e.g. Fidelity SPAXX) in
          # the balances endpoint's `cash` figure while ALSO reporting them as
          # positions with `cash_equivalent: true`. Those positions are imported as
          # holdings, so their value must come out of cash here — otherwise the
          # account total counts the same money twice. Subtract in the currency the
          # stored cash is actually denominated in (upsert_balances! can fall back
          # to a USD/first entry), not the account currency.
          cash_currency = snaptrade_account.primary_cash_currency
          cash_equivalent_value = snaptrade_account.cash_equivalent_position_value(cash_currency)

          # No floor: negative cash is legitimate for margin accounts, and
          # clamping would silently skew the calculated total. The before/after
          # values in the debug entry let support distinguish real margin from
          # a stale holdings snapshot over-subtracting.
          adjusted_cash = cash - cash_equivalent_value

          if cash_equivalent_value.nonzero?
            DebugLogEntry.capture(
              category: "provider_sync",
              level: "info",
              message: "Excluded cash-equivalent (money market) positions already counted in SnapTrade cash balance",
              source: self.class.name,
              provider_key: "snaptrade",
              family: snaptrade_account.snaptrade_item.family,
              account_provider: snaptrade_account.account_provider,
              metadata: {
                snaptrade_account_id: snaptrade_account.id,
                currency: cash_currency,
                cash_equivalent_value: cash_equivalent_value.to_s("F"),
                cash_balance_before: cash.to_s("F"),
                cash_balance_after: adjusted_cash.to_s("F")
              }
            )
          end

          adjusted_cash
        end
      end
    end

    def calculate_holdings_value
      holdings_data = snaptrade_account.raw_holdings_payload || []
      return 0 if holdings_data.empty?

      holdings_data.sum do |holding|
        data = holding.is_a?(Hash) ? holding.with_indifferent_access : {}
        units = parse_decimal(data[:units]) || 0
        price = parse_decimal(data[:price]) || 0
        units * price * contract_multiplier(extract_symbol_data(data))
      end
    end

    # Every position has units and a price, and there is no cash in another
    # currency: that cash is imported as a holding, so it is in the API total
    # but not in holdings plus cash.
    def net_short_total_complete?
      positions_complete = Array(snaptrade_account.raw_holdings_payload).all? do |holding|
        data = holding.is_a?(Hash) ? holding.with_indifferent_access : {}
        parse_decimal(data[:units]).present? && parse_decimal(data[:price]).present?
      end

      positions_complete && snaptrade_account.non_primary_cash_entries.none? { |entry| parse_decimal(entry[:amount])&.nonzero? }
    end

    def use_api_total_balance?
      return false unless snaptrade_account.current_balance.present?

      holdings_currencies.any? { |currency| currency.present? && currency != snaptrade_account.currency }
    end

    def holdings_currencies
      Array(snaptrade_account.raw_holdings_payload).filter_map do |holding|
        data = holding.respond_to?(:with_indifferent_access) ? holding.with_indifferent_access : {}
        extract_currency(data, extract_symbol_data(data), snaptrade_account.currency)
      end.uniq
    end
end
