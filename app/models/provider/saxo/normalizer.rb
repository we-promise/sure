class Provider::Saxo::Normalizer
  SUPPORTED_ASSETS = %w[Stock Etf Etc].freeze
  PRINCIPAL_TYPES = %w[shareamount tradeamount].freeze

  def self.decimal(value)
    result = BigDecimal(value.to_s)
    raise Provider::Saxo::Error, "Saxo amount is not finite" unless result.finite?
    result
  rescue ArgumentError, TypeError
    raise Provider::Saxo::Error, "Saxo amount is missing or invalid"
  end

  def self.date(value)
    Date.iso8601(value.to_s.first(10))
  rescue Date::Error
    raise Provider::Saxo::Error, "Saxo date is missing or invalid"
  end

  def initialize(account_id:, currency:)
    @account_id, @currency = account_id, currency
  end

  def call(rows)
    bookings = {}
    trades = {}
    rows.each do |row|
      raise Provider::Saxo::Error, "Saxo transaction belongs to another account" unless row["AccountId"] == @account_id
      next if row["IsIntradayData"] || row["IsIntraDay"]
      raise Provider::Saxo::Error, "Saxo history currency is missing" unless row["Currency"].to_s.match?(/\A[A-Z]{3}\z/)
      cash = row["Bookings"]
      cash = [] if cash.nil? && self.class.decimal(row["BookedAmount"]).zero?
      raise Provider::Saxo::Error, "Saxo bookings are incomplete" unless cash.is_a?(Array) && cash.all? { |booking| booking.is_a?(Hash) }
      if row["BookedAmount"].present? && cash.sum { |booking| self.class.decimal(booking["BookedAmount"]) } != self.class.decimal(row["BookedAmount"])
        raise Provider::Saxo::Error, "Saxo cash bookings do not reconcile"
      end
      cash = cash.map { |booking| in_account_currency(booking, row.fetch("Currency")) }
      movements = Array(row["Trades"])
      raise Provider::Saxo::Error, "Saxo security movements are incomplete" unless movements.all? { |movement| movement.is_a?(Hash) }
      instrument = row["Instrument"]
      cash_only_instrument = instrument.is_a?(Hash) && instrument["AssetType"] == "Cash" &&
        row["TransactionType"] != "Trade" && movements.empty?
      validate_instrument!(instrument, location: "transaction") if instrument.present? && !cash_only_instrument
      principals = cash.select { |booking| PRINCIPAL_TYPES.include?(booking["AmountType"].to_s.downcase.delete(" _-")) }
      if row["TransactionType"] == "Trade"
        raise Provider::Saxo::Error, "Saxo trade has multiple security movements" unless movements.one?
        movement = movements.first
        instrument = movement["Instrument"] || row["Instrument"] || {}
        validate_instrument!(instrument, location: movement["Instrument"].present? ? "trade" : "transaction")
        event = row["Event"].to_s.delete(" _-")
        quantity = self.class.decimal(movement["TradedQuantity"])
        transfer = %w[TransferIn TransferOut].include?(event)
        unless transfer || (%w[Buy Sell].include?(event) && principals.any?)
          diagnostic = {
            stage: "history", reason: "unsupported_trade", event: diagnostic_label(row["Event"]),
            trade_event_type: diagnostic_label(movement["TradeEventType"]),
            booking_types: cash.map { |booking| diagnostic_label(booking["AmountType"]) }.uniq.first(20),
            booking_count: cash.size, principal_count: principals.size,
            quantity_direction: quantity.positive? ? "positive" : (quantity.negative? ? "negative" : "zero")
          }
          raise Provider::Saxo::Error.new("Saxo trade principal or direction is not supported", diagnostic: diagnostic)
        end
        amount = -principals.sum { |booking| self.class.decimal(booking.fetch("BookedAmount")) }
        expected_direction = %w[Buy TransferIn].include?(event) ? 1 : -1
        expected_direction *= -1 if row["IsReversal"]
        unless quantity * expected_direction > 0 && (transfer || amount * expected_direction > 0)
          raise Provider::Saxo::Error, "Saxo trade direction does not reconcile with its cash principal"
        end
        price = self.class.decimal(movement["Price"])
        raise Provider::Saxo::Error, "Saxo trade price or quantity is invalid" if price.negative? || quantity.zero?
        put!(trades, text!(movement, "TradeId"), {
          instrument: instrument, quantity: quantity, price: price,
          amount: amount, currency: @currency, date: self.class.date(row["Date"]),
          activity_label: transfer ? "Transfer" : (quantity.positive? ? "Buy" : "Sell"),
          # Entry and price share a currency in Sure. Convert only with an explicit Saxo rate.
          conversion_rate: instrument["Currency"] == @currency || (transfer && price.zero?) ? BigDecimal("1") : conversion_rate!(principals)
        })
      elsif movements.any?
        raise Provider::Saxo::Error, "Saxo corporate action with security movements requires review"
      end
      cash.each do |booking|
        amount = self.class.decimal(booking["BookedAmount"])
        next if amount.zero? || (row["TransactionType"] == "Trade" && principals.include?(booking))
        put!(bookings, text!(booking, "BookingId"), {
          amount: -amount, currency: @currency,
          date: self.class.date(booking["Date"] || row["Date"]),
          name: [ row["TransactionDescription"] || row["EventDisplay"], booking["AmountTypeDisplay"] || booking["AmountType"] ].compact.join(" - ").presence || text!(booking, "BookingId"),
          activity_label: activity_label(booking, row),
          extra: { "saxo" => { "amount_type" => booking["AmountType"], "conversion_rate" => booking["ConversionRate"],
            "source_currency" => row["Currency"], "account_to_source_rate" => booking["ConversionRateAccountToClientCurrency"] } }
        })
      end
      if cash.empty? && !self.class.decimal(row["BookedAmount"] || 0).zero?
        raise Provider::Saxo::Error, "Saxo cash transaction has no bookings"
      end
    end
    { trades: trades, bookings: bookings }
  end

  private
    def diagnostic_label(value)
      return value if value.is_a?(String) && value.match?(/\A[A-Za-z][A-Za-z _-]{0,59}\z/)
      nil
    end

    def in_account_currency(booking, source_currency)
      return booking if source_currency == @currency
      rate = self.class.decimal(booking["ConversionRateAccountToClientCurrency"])
      raise Provider::Saxo::Error, "Saxo account currency conversion is incomplete" unless rate.positive?
      converted = booking.merge("BookedAmount" => self.class.decimal(booking["BookedAmount"]) / rate)
      converted["ConversionRate"] = self.class.decimal(booking["ConversionRate"]) / rate if booking["ConversionRate"].present?
      converted
    end

    def text!(row, key)
      value = row[key].to_s
      raise Provider::Saxo::Error, "Saxo #{key} is missing" if value.empty?
      value
    end

    def put!(collection, key, value)
      raise Provider::Saxo::Error, "Saxo identifier has conflicting values" if collection.key?(key) && collection[key] != value
      collection[key] = value
    end

    def validate_instrument!(instrument, location:)
      asset_type = instrument.is_a?(Hash) ? instrument["AssetType"] : nil
      uic_present = instrument.is_a?(Hash) && instrument["Uic"].present?
      currency_valid = instrument.is_a?(Hash) && instrument["Currency"].to_s.match?(/\A[A-Z]{3}\z/)
      return if SUPPORTED_ASSETS.include?(asset_type) && uic_present && currency_valid

      diagnostic = { stage: "history", location: location, uic_present: uic_present, currency_valid: currency_valid }
      diagnostic[:asset_type] = asset_type if asset_type.is_a?(String) && asset_type.match?(/\A[A-Za-z]{1,40}\z/)
      raise Provider::Saxo::Error.new("Saxo instrument type is not supported", diagnostic: diagnostic)
    end

    def conversion_rate!(principals)
      rates = principals.map { |booking| self.class.decimal(booking["ConversionRate"]) }.uniq
      raise Provider::Saxo::Error, "Saxo currency conversion is incomplete" unless rates.one? && rates.first.positive?
      rates.first
    end

    def activity_label(booking, row)
      type = booking["AmountType"].to_s.downcase
      return "Dividend" if type.include?("dividend")
      return "Other" if type.include?("tax") || type.include?("duty")
      return "Fee" if type.include?("fee") || type.include?("commission") || type.include?("cost")
      return "Interest" if type.include?("interest")
      return "Transfer" if row["TransactionType"] == "CashTransfer"
      nil
    end
end
