class Trade::CreateForm
  include ActiveModel::Model

  SECURITY_TRADE_LABELS = {
    "buy" => "Buy",
    "sell" => "Sell",
    "option_buy" => "Buy",
    "option_sell" => "Sell",
    "sweep_in" => "Sweep In",
    "sweep_out" => "Sweep Out",
    "reinvestment" => "Reinvestment"
  }.freeze

  CASH_TRADE_LABELS = {
    "dividend" => "Dividend",
    "interest" => "Interest",
    "fee" => "Fee"
  }.freeze

  ACTIVITY_LABELS = SECURITY_TRADE_LABELS.merge(CASH_TRADE_LABELS).freeze
  TRANSFER_TYPES = %w[deposit withdrawal].freeze
  SUPPORTED_TYPES = (ACTIVITY_LABELS.keys + TRANSFER_TYPES).freeze

  attr_accessor :account, :date, :amount, :currency, :qty,
                :price, :fee, :ticker, :manual_ticker, :type, :transfer_account_id,
                :underlying_ticker, :option_type, :strike_price, :expiration_date, :contract_multiplier

  validate :option_details_must_be_valid

  # Either creates a trade, transaction, or transfer based on type
  # Returns the model, regardless of success or failure
  def create
    case type
    when *SECURITY_TRADE_LABELS.keys
      create_trade
    when "dividend"
      create_dividend_income
    when "interest"
      create_interest_income
    when "fee"
      create_fee
    when "deposit", "withdrawal"
      create_transfer
    end
  end

  private
    # Users can either look up a ticker from a provider or enter a manual, "offline" ticker (that we won't fetch prices for)
    def security
      parsed = ticker.present? ? Security.parse_combobox_id(ticker) : { ticker: manual_ticker }
      return nil if parsed[:ticker].blank?

      Security::Resolver.new(
        parsed[:ticker],
        exchange_operating_mic: parsed[:exchange_operating_mic],
        price_provider: parsed[:price_provider]
      ).resolve
    end

    def ticker_present?
      ticker.present? || manual_ticker.present?
    end

    def create_trade
      return entry_with_form_errors if option_trade? && !valid?

      sec = option_trade? ? option_security : security

      unless sec
        entry = account.entries.build(entryable: Trade.new)
        entry.errors.add(:base, I18n.t("trades.form.trade_requires_security"))
        return entry
      end

      signed_qty = sell_side_trade? ? -qty.to_d.abs : qty.to_d.abs
      multiplier = option_trade? ? contract_multiplier.to_i : 1
      signed_amount = signed_qty * price.to_d * multiplier + fee.to_d
      label = SECURITY_TRADE_LABELS.fetch(type)

      trade_entry = account.entries.new(
        name: trade_name(label, signed_qty.abs, sec),
        date: date,
        amount: signed_amount,
        currency: currency,
        entryable: Trade.new(
          qty: signed_qty,
          price: price,
          fee: fee.to_d,
          currency: currency,
          security: sec,
          contract_multiplier: multiplier,
          investment_activity_label: label
        )
      )

      if trade_entry.save
        trade_entry.lock_saved_attributes!
        account.sync_later
      end

      trade_entry
    end

    # Dividends are always a Trade. Security is required.
    def create_dividend_income
      unless ticker_present?
        entry = account.entries.build(entryable: Trade.new)
        entry.errors.add(:base, I18n.t("trades.form.dividend_requires_security"))
        return entry
      end

      begin
        sec = security
        label = CASH_TRADE_LABELS.fetch("dividend")
        create_income_trade(sec: sec, label: label, name: "#{label}: #{sec.ticker}")
      rescue => e
        Rails.logger.warn("Dividend security resolution failed: #{e.class} - #{e.message}")
        entry = account.entries.build(entryable: Trade.new)
        entry.errors.add(:base, I18n.t("trades.form.dividend_requires_security"))
        entry
      end
    end

    # Interest in an investment account is always a Trade.
    # Falls back to a synthetic cash security when none is selected.
    def create_interest_income
      sec = ticker_present? ? security : Security.cash_for(account, currency: currency)
      label = CASH_TRADE_LABELS.fetch("interest")
      name = sec.cash? ? label : "#{label}: #{sec.ticker}"
      create_income_trade(sec: sec, label: label, name: name)
    end

    def create_fee
      sec = ticker_present? ? security : Security.cash_for(account, currency: currency)
      label = CASH_TRADE_LABELS.fetch("fee")
      name = sec.cash? ? label : "#{label}: #{sec.ticker}"
      create_income_trade(sec: sec, label: label, name: name, amount_sign: 1)
    end

    def create_income_trade(sec:, label:, name:, amount_sign: -1)
      entry = account.entries.build(
        name: name,
        date: date,
        amount: amount.to_d.abs * amount_sign,
        currency: currency,
        entryable: Trade.new(
          qty: 0,
          price: 0,
          fee: 0,
          currency: currency,
          security: sec,
          investment_activity_label: label
        )
      )

      if entry.save
        entry.lock_saved_attributes!
        account.sync_later
      end

      entry
    end

    def sell_side_trade?
      %w[sell option_sell sweep_out].include?(type)
    end

    def option_trade?
      %w[option_buy option_sell].include?(type)
    end

    def option_security
      option_ticker = Security.option_ticker(
        underlying_ticker: underlying_ticker,
        option_type: option_type,
        strike_price: strike_price,
        expiration_date: expiration_date,
        contract_multiplier: contract_multiplier
      )
      security = Security.find_or_initialize_by(ticker: option_ticker)
      security.assign_attributes(
        name: option_name,
        option_type: option_type,
        underlying_ticker: underlying_ticker.to_s.strip.upcase,
        strike_price: strike_price,
        expiration_date: expiration_date,
        contract_multiplier: contract_multiplier,
        offline: true
      )
      security.save!
      security
    end

    def option_name
      strike = BigDecimal(strike_price.to_s).to_s("F").sub(/\.0+\z/, "").sub(/(\.\d*?)0+\z/, "\\1")
      "#{underlying_ticker.to_s.strip.upcase} $#{strike} #{option_type.to_s.upcase} · #{expiration_date}"
    end

    def option_details_must_be_valid
      return unless option_trade?

      errors.add(:underlying_ticker, :blank) if underlying_ticker.blank?
      errors.add(:option_type, :inclusion) unless Security::OPTION_TYPES.include?(option_type)
      errors.add(:strike_price, :greater_than, count: 0) unless decimal_value(strike_price)&.positive?
      errors.add(:expiration_date, :invalid) unless parsed_expiration_date
      errors.add(:contract_multiplier, :greater_than, count: 0) unless contract_multiplier.to_s.match?(/\A[1-9]\d*\z/)
      errors.add(:qty, :greater_than, count: 0) unless decimal_value(qty)&.positive?
      errors.add(:price, :greater_than_or_equal_to, count: 0) unless decimal_value(price)&.nonnegative?
      errors.add(:fee, :greater_than_or_equal_to, count: 0) if fee.present? && !decimal_value(fee)&.nonnegative?
    end

    def decimal_value(value)
      return if value.blank?

      number = BigDecimal(value.to_s)
      number if number.finite?
    rescue ArgumentError
      nil
    end

    def parsed_expiration_date
      Date.iso8601(expiration_date.to_s)
    rescue Date::Error
      nil
    end

    def entry_with_form_errors
      entry = account.entries.build(entryable: Trade.new)
      errors.each { |error| entry.errors.add(error.attribute, error.message) }
      entry
    end

    def trade_name(label, quantity, security)
      if option_trade?
        I18n.t("trades.form.option_trade_name", label: label, qty: quantity, security: security.name)
      elsif %w[buy sell].include?(type)
        Trade.build_name(type, quantity, security.ticker)
      else
        "#{label} #{quantity.to_d} shares of #{security.ticker}"
      end
    end

    def create_transfer
      if transfer_account_id.present?
        from_account_id = type == "withdrawal" ? account.id : transfer_account_id
        to_account_id = type == "withdrawal" ? transfer_account_id : account.id

        Transfer::Creator.new(
          family: account.family,
          source_account_id: from_account_id,
          destination_account_id: to_account_id,
          date: date,
          amount: amount
        ).create
      else
        create_unlinked_transfer
      end
    end

    # If user doesn't provide the reciprocal account, it's a regular transaction
    def create_unlinked_transfer
      signed_amount = type == "deposit" ? amount.to_d * -1 : amount.to_d

      entry = account.entries.build(
        name: signed_amount < 0 ? "Deposit to #{account.name}" : "Withdrawal from #{account.name}",
        date: date,
        amount: signed_amount,
        currency: currency,
        entryable: Transaction.new
      )

      if entry.save
        entry.lock_saved_attributes!
        account.sync_later
      end

      entry
    end
end
