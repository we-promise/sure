class Trade::CreateForm
  include ActiveModel::Model

  attr_accessor :account, :date, :amount, :currency, :qty,
                :price, :fee, :ticker, :manual_ticker, :type, :transfer_account_id

  # Either creates a trade, transaction, or transfer based on type
  # Returns the model, regardless of success or failure
  def create
    case type
    when "buy", "sell"
      create_trade
    when "dividend"
      create_dividend_income
    when "interest"
      create_interest_income
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
      signed_qty = type == "sell" ? -qty.to_d : qty.to_d
      signed_amount = signed_qty * price.to_d + fee.to_d

      trade_entry = account.entries.new(
        name: Trade.build_name(type, qty, security.ticker),
        date: date,
        amount: signed_amount,
        currency: currency,
        entryable: Trade.new(
          qty: signed_qty,
          price: price,
          fee: fee.to_d,
          currency: currency,
          security: security,
          investment_activity_label: type.capitalize # "buy" → "Buy", "sell" → "Sell"
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
        create_income_trade(sec: sec, label: "Dividend", name: "Dividend: #{sec.ticker}")
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
      sec = ticker_present? ? security : Security.cash_for(account)
      name = sec.cash? ? "Interest" : "Interest: #{sec.ticker}"
      create_income_trade(sec: sec, label: "Interest", name: name)
    end

    def create_income_trade(sec:, label:, name:)
      entry = account.entries.build(
        name: name,
        date: date,
        amount: amount.to_d * -1,
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
