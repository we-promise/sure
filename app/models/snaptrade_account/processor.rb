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

    def update_account_balance(account)
      # Calculate total balance and cash balance from SnapTrade data
      total_balance = calculate_total_balance
      cash_balance = calculate_cash_balance

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
      # Calculate total from holdings + cash for accuracy
      # SnapTrade's current_balance can sometimes be stale or just the cash value
      holdings_value = calculate_holdings_value
      cash_value = calculate_cash_balance
      calculated_total = holdings_value + cash_value

      reconciliation = option_position_reconciliation
      use_provider_total = use_api_total_balance?(reconciliation, calculated_total, cash_value, holdings_value)
      if use_provider_total
        capture_partial_positions(reconciliation, calculated_total, holdings_value, cash_value, decision: "provider_total") if
          reconciliation[:confirmed].any? || reconciliation[:suspected].any?
        Rails.logger.debug "SnaptradeAccount::Processor - Using API total for incomplete or multi-currency holdings for snaptrade_account=#{snaptrade_account.id}"
        return snaptrade_account.current_balance
      end

      capture_partial_positions(reconciliation, calculated_total, holdings_value, cash_value, decision: "calculated_total") if
        reconciliation[:confirmed].any? || reconciliation[:suspected].any?

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

    def use_api_total_balance?(reconciliation = option_position_reconciliation, calculated_total = nil, cash_value = nil, holdings_value = nil)
      api_total = snaptrade_account.current_balance
      return false unless api_total.present?
      return true if holdings_currencies.any? { |currency| currency.present? && currency != snaptrade_account.currency }
      return false unless reconciliation[:confirmed].any?

      calculated_total ||= 0
      cash_value ||= calculate_cash_balance
      holdings_value ||= calculate_holdings_value
      missing_long = reconciliation[:confirmed].select { |option| option[:quantity].positive? }
      missing_short = reconciliation[:confirmed].select { |option| option[:quantity].negative? }
      return false if missing_long.any? && missing_short.any?

      missing_value = reconciliation[:confirmed].sum do |option|
        option[:quantity] * option[:reference_price] * option[:multiplier]
      end
      expected_total = calculated_total + missing_value
      tolerance = [ BigDecimal("0.01"), missing_value.abs * BigDecimal("0.25") ].max
      provider_is_cash_only = holdings_value.nonzero? && (api_total - cash_value).abs < BigDecimal("0.01")

      return false if provider_is_cash_only
      return false if missing_long.any? && api_total <= calculated_total
      return false if missing_short.any? && api_total >= calculated_total
      return false if (api_total - expected_total).abs > tolerance
      return false if api_total <= 0 && holdings_value.positive?

      true
    end

    def missing_open_options
      option_position_reconciliation[:confirmed]
    end

    def option_position_reconciliation
      @option_position_reconciliation ||= begin
        expected = Hash.new(BigDecimal("0"))
        reported = Hash.new(BigDecimal("0"))
        display_tickers = {}
        reference_prices = {}
        multipliers = {}
        unreliable_contracts = Set.new
        global_uncertainty = false

        activities = Array(snaptrade_account.raw_activities_payload).uniq do |activity|
          activity.is_a?(Hash) ? activity["id"] || activity[:id] || activity.object_id : activity.object_id
        end

        activities.each do |activity|
          data = activity.respond_to?(:with_indifferent_access) ? activity.with_indifferent_access : {}
          option = data[:option_symbol]
          next if option.blank?

          key = canonical_option_identifier(option)
          unless key
            global_uncertainty = true
            next
          end

          option_data = option.with_indifferent_access
          display_tickers[key] ||= option_data[:ticker].to_s.upcase.strip
          reference_prices[key] = parse_decimal(data[:price]) if parse_decimal(data[:price])&.positive?
          multipliers[key] ||= contract_multiplier({}, option_data)
          quantity = parse_decimal(data[:units])
          effect = option_activity_effect(data[:type].to_s.upcase)

          if effect == :unknown || quantity.nil?
            unreliable_contracts << key
            expected[key] += 0
            next
          end

          case effect
          when :add
            expected[key] += quantity.abs
          when :subtract
            unreliable_contracts << key if expected[key].zero?
            expected[key] -= quantity.abs
          when :close
            if expected[key].zero? || quantity.zero? || quantity.abs > expected[key].abs
              unreliable_contracts << key
            else
              expected[key] -= expected[key].positive? ? quantity.abs : -quantity.abs
            end
          when :ignore
            next
          end
        end

        Array(snaptrade_account.raw_holdings_payload).each do |holding|
          data = holding.respond_to?(:with_indifferent_access) ? holding.with_indifferent_access : {}
          symbol_data = extract_symbol_data(data)
          next unless option_symbol?(symbol_data)

          key = canonical_option_identifier(symbol_data)
          unless key
            global_uncertainty = true
            next
          end

          quantity = parse_decimal(data[:units])
          if quantity.nil?
            unreliable_contracts << key
            next
          end

          display_tickers[key] ||= symbol_data[:symbol].to_s.upcase.strip
          reference_prices[key] = parse_decimal(data[:price]) if parse_decimal(data[:price])&.positive?
          multipliers[key] ||= contract_multiplier(symbol_data)
          reported[key] += quantity
        end

        entries = (expected.keys | reported.keys | unreliable_contracts.to_a).filter_map do |key|
          difference = expected[key] - reported[key]
          next if difference.zero? && !unreliable_contracts.include?(key)

          unreliable_contracts << key if expected[key].zero? && reported[key].nonzero?
          {
            key: key,
            ticker: display_tickers[key],
            quantity: difference,
            expected_quantity: expected[key],
            position_quantity: reported[key],
            reference_price: reference_prices[key],
            multiplier: multipliers[key],
            reason: unreliable_contracts.include?(key) ? "uncertain_activity" : "quantity_mismatch"
          }
        end

        history_complete = activity_history_complete?
        trusted = history_complete && !global_uncertainty
        confirmed, suspected = entries.partition { |entry| trusted && !unreliable_contracts.include?(entry[:key]) }
        confirmed.each { |entry| entry.delete(:key) }
        suspected.each { |entry| entry.delete(:key) }

        { confirmed: confirmed, suspected: suspected, history_complete: history_complete, trusted: trusted }
      end
    end

    def option_activity_effect(activity_type)
      case activity_type
      when "BUY", "OPTION_BUY", "REI", "REINVEST", "EXTERNAL_ASSET_TRANSFER_IN", "INTERNAL_ASSET_TRANSFER_IN"
        :add
      when "SELL", "OPTION_SELL", "EXTERNAL_ASSET_TRANSFER_OUT", "INTERNAL_ASSET_TRANSFER_OUT"
        :subtract
      when "OPTIONASSIGNMENT", "ASSIGNED", "OPTIONEXERCISE", "EXERCISED", "OPTIONEXPIRATION", "EXPIRED"
        :close
      when "DIVIDEND", "CONTRIBUTION", "WITHDRAWAL", "FEE", "TAX", "INTEREST", "TRANSFER"
        :ignore
      else
        :unknown
      end
    end

    def canonical_option_identifier(value)
      data = value.respond_to?(:with_indifferent_access) ? value.with_indifferent_access : {}
      ticker = data[:ticker] || data[:symbol]
      ticker = ticker[:symbol] if ticker.is_a?(Hash)
      compact = ticker.to_s.upcase.gsub(/\s+/, "")

      if (match = /\A(?<root>[A-Z0-9.\/-]{1,6})(?<expiration>\d{6})(?<right>[CP])(?<strike>\d{8})\z/.match(compact))
        return [ match[:root], match[:expiration], match[:right], match[:strike] ].join("|")
      end

      underlying = data.dig(:underlying_symbol, :symbol) || data.dig(:underlying, :symbol)
      expiration = parse_date(data[:expiration_date])
      right = data[:option_type].to_s.upcase
      right = right.first if right.in?(%w[CALL PUT])
      strike = parse_decimal(data[:strike_price])
      return nil if underlying.blank? || expiration.nil? || !right.in?(%w[C P]) || strike.nil?

      [ underlying.to_s.upcase.gsub(/\s+/, ""), expiration.strftime("%y%m%d"), right,
        (strike * 1000).to_i.to_s.rjust(8, "0") ].join("|")
    end

    def activity_history_complete?
      return false if snaptrade_account.sync_start_date.present?
      return false unless snaptrade_account.raw_activities_payload.is_a?(Array)

      sync_status = snaptrade_account.raw_payload.to_h.dig("sync_status", "transactions").to_h
      first_transaction_on = parse_date(sync_status["first_transaction_date"])
      initial_sync_completed = ActiveModel::Type::Boolean.new.cast(sync_status["initial_sync_completed"])
      return false if first_transaction_on.nil? || first_transaction_on > Date.current || !initial_sync_completed

      dates = Array(snaptrade_account.raw_activities_payload).filter_map do |activity|
        data = activity.respond_to?(:with_indifferent_access) ? activity.with_indifferent_access : {}
        parse_date(data[:trade_date] || data[:settlement_date] || data[:date])
      end
      dates.present? && dates.min <= first_transaction_on
    end

    def capture_partial_positions(reconciliation, calculated_total, holdings_value, cash_value, decision:)
      confirmed = reconciliation[:confirmed]
      suspected = reconciliation[:suspected]
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: decision == "provider_total" ?
          "Using SnapTrade account total because open option positions are missing" :
          "Keeping calculated SnapTrade total because option position evidence is incomplete or conflicts",
        source: self.class.name,
        provider_key: "snaptrade",
        family: snaptrade_account.snaptrade_item.family,
        account_provider: snaptrade_account.account_provider,
        metadata: {
          snaptrade_account_id: snaptrade_account.id,
          decision: decision,
          history_complete: reconciliation[:history_complete],
          trusted: reconciliation[:trusted],
          missing_options: confirmed.map { |option| option_reconciliation_metadata(option) },
          suspected_options: suspected.map { |option| option_reconciliation_metadata(option) },
          provider_total: snaptrade_account.current_balance&.to_s("F"),
          calculated_total: calculated_total.to_s("F"),
          holdings_value: holdings_value.to_s("F"),
          cash_value: cash_value.to_s("F")
        }
      )
    end

    def option_reconciliation_metadata(option)
      {
        ticker: option[:ticker],
        quantity: option[:quantity].to_s("F"),
        expected_quantity: option[:expected_quantity].to_s("F"),
        position_quantity: option[:position_quantity].to_s("F"),
        reference_price: option[:reference_price]&.to_s("F"),
        multiplier: option[:multiplier]&.to_s("F"),
        reason: option[:reason]
      }
    end

    def holdings_currencies
      Array(snaptrade_account.raw_holdings_payload).filter_map do |holding|
        data = holding.respond_to?(:with_indifferent_access) ? holding.with_indifferent_access : {}
        extract_currency(data, extract_symbol_data(data), snaptrade_account.currency)
      end.uniq
    end
end
