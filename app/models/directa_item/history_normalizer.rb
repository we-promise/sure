# frozen_string_literal: true

require "csv"
require "digest"
require "json"

class DirectaItem::HistoryNormalizer
  MIN_DATE = Date.new(2018, 1, 1)
  BANK_TIME_ZONE = "Europe/Rome".freeze
  MAX_ORDERS = 10_000
  MAX_STATEMENTS = 120
  MAX_STATEMENT_BYTES = 2 * 1024 * 1024
  MAX_TOTAL_STATEMENT_BYTES = 32 * 1024 * 1024
  MAX_CSV_ROWS = 10_000
  MAX_TEXT_BYTES = 2_048
  CONTROL_PATTERN = /[\u0000-\u0009\u000B\u000C\u000E-\u001F\u007F-\u009F]/
  BANK_SCOPE_PATTERN = /\A[0-9a-f]{64}\z/
  REFERENCE_PATTERN = /\A[A-Z0-9]{14}\z/
  CURRENCY_PATTERN = /\A[A-Z]{3}\z/
  ITALIAN_INTEGER_PATTERN = /\A(?<sign>[+-]?)(?<whole>\d{1,3}(?:\.\d{3})+|\d+)\z/
  ITALIAN_DECIMAL_PATTERN = /\A(?<sign>[+-]?)(?<whole>\d{1,3}(?:\.\d{3})+|\d+)(?:,(?<fraction>\d+))?\z/
  CSV_HEADER = [ "data", "valuta", "titolo", "riferim.", "Prezzo", "", "quantita'", "importo EUR", "comm." ].freeze

  Activity = Data.define(
    :date,
    :isin,
    :name,
    :quantity,
    :price,
    :amount,
    :fee,
    :currency,
    :external_id,
    :fingerprint,
    :occurrence,
    :metadata
  ) do
    def inspect
      "#<#{self.class.name}: activity>"
    end
    alias to_s inspect
  end

  Result = Data.define(:activities, :cohorts) do
    def inspect
      "#<#{self.class.name}: activities=#{activities.length} dates=#{cohorts.length}>"
    end
    alias to_s inspect
  end

  Order = Data.define(
    :reference,
    :side,
    :isin,
    :name,
    :currency,
    :quantity,
    :average_price,
    :placement_date,
    :event_date
  ) do
    def signed_quantity
      side == "C" ? quantity : -quantity
    end

    def inspect
      "#<#{self.class.name}: order>"
    end
    alias to_s inspect
  end

  Statement = Data.define(:requested_date, :from_date, :to_date, :trade_rows, :row_count) do
    def inspect
      "#<#{self.class.name}: statement rows=#{trade_rows.length}>"
    end
    alias to_s inspect
  end

  TradeRow = Data.define(
    :date,
    :value_date,
    :reference,
    :quote_price,
    :quote_price_text,
    :currency,
    :quantity,
    :gross_eur,
    :commission_eur,
    :commission_reported
  ) do
    def inspect
      "#<#{self.class.name}: trade_row>"
    end
    alias to_s inspect
  end

  def initialize(orders:, statements:, bank_scope:, coverage_start:, coverage_end:)
    @orders = orders
    @statements = statements
    @bank_scope = bank_scope
    @coverage_start = coverage_start
    @coverage_end = coverage_end
  end

  def normalize
    validate_inputs!
    orders_by_reference = parse_orders
    statements = parse_statements(orders_by_reference)
    rows_by_reference = match_statement_rows(statements, orders_by_reference)
    activities = build_activities(rows_by_reference, orders_by_reference)
    Result.new(activities: activities.freeze, cohorts: build_cohorts(activities))
  rescue DirectaItem::PortfolioNormalizer::Error
    raise
  rescue CSV::MalformedCSVError, EncodingError, Date::Error, ArgumentError, KeyError, TypeError
    invalid_data!
  end

  def inspect
    "#<#{self.class.name}: redacted>"
  end
  alias to_s inspect

  private

    def validate_inputs!
      invalid_data! unless @bank_scope.is_a?(String) && @bank_scope.match?(BANK_SCOPE_PATTERN)
      invalid_data! unless @coverage_start.instance_of?(Date) && @coverage_end.instance_of?(Date)
      invalid_data! unless @coverage_start >= MIN_DATE && @coverage_start.day == 1 && @coverage_end >= @coverage_start

      bank_yesterday = Time.current.in_time_zone(BANK_TIME_ZONE).to_date - 1.day
      invalid_data! if @coverage_end > bank_yesterday
      invalid_data! unless @orders.is_a?(Array) && @orders.length <= MAX_ORDERS
      invalid_data! unless @statements.is_a?(Hash) && @statements.length <= MAX_STATEMENTS

      statement_keys = @statements.keys
      invalid_data! unless statement_keys.all? { |date| date.instance_of?(Date) }
      incomplete! unless statement_keys.map { |date| [ date.year, date.month ] }.uniq.length == statement_keys.length
    end

    def parse_orders
      orders = {}
      @orders.each do |row|
        validate_order_shape!(row)
        reference = row.fetch("Riferimento")
        unless reference.is_a?(String) && reference == reference.strip && reference.match?(REFERENCE_PATTERN)
          invalid_data!
        end
        incomplete! if orders.key?(reference)
        reference = reference.dup.freeze

        status = row.fetch("Stato")
        invalid_data! unless status.is_a?(String)
        unsupported_activity! unless status.strip == "e"

        side = row.fetch("AcqVen")
        invalid_data! unless side.is_a?(String)
        side = side.strip
        unsupported_activity! unless %w[C V].include?(side)

        requested_quantity = positive_integer(row.fetch("QuantitaOrdine"))
        executed_quantity = positive_integer(row.fetch("QuantitaEseguita"))
        incomplete! unless requested_quantity == executed_quantity

        event_date = order_date(row.fetch("DataEvento"))
        incomplete! unless event_date.between?(@coverage_start, @coverage_end)
        placement_date = order_date(row.fetch("DataImmissione"))
        incomplete! unless placement_date >= MIN_DATE && placement_date <= event_date

        isin = required_string(row.fetch("Isin"), max_bytes: 12).upcase
        invalid_data! unless DirectaItem::PortfolioNormalizer.valid_isin?(isin)

        name = required_string(row.fetch("Descrizione"), max_bytes: MAX_TEXT_BYTES)
        currency = required_string(row.fetch("Divisa"), max_bytes: 8).strip
        invalid_data! unless currency.match?(CURRENCY_PATTERN)
        unsupported_activity! unless %w[EUR USD].include?(currency)

        average_price = provider_decimal(row.fetch("PrezzoMedio"))
        invalid_data! unless average_price.positive?

        quantity = BigDecimal(executed_quantity.to_s)
        invalid_data! unless fits_database_decimal?(quantity, precision: 34, scale: 18)

        orders[reference] = Order.new(
          reference: reference,
          side: side.freeze,
          isin: isin.freeze,
          name: name.freeze,
          currency: currency.freeze,
          quantity: quantity,
          average_price: average_price,
          placement_date: placement_date,
          event_date: event_date
        )
      end
      orders.freeze
    end

    def validate_order_shape!(row)
      unless row.is_a?(Hash) && row.length <= 64 &&
          row.all? { |key, value| key.is_a?(String) && key.bytesize <= 64 && safe_order_value?(value) }
        invalid_data!
      end
      %w[Riferimento Stato AcqVen QuantitaOrdine QuantitaEseguita DataEvento DataImmissione Isin Descrizione Divisa PrezzoMedio].each do |key|
        invalid_data! unless row.key?(key)
      end
    end

    def safe_order_value?(value)
      case value
      when String
        value.bytesize <= MAX_TEXT_BYTES && value.valid_encoding? && !value.match?(CONTROL_PATTERN)
      when Integer, NilClass, TrueClass, FalseClass
        !value.is_a?(Integer) || value.bit_length <= 213
      when Float
        value.finite?
      else
        false
      end
    end

    def parse_statements(orders)
      required_dates = required_statement_dates(orders)
      supplied_dates = @statements.keys.sort
      incomplete! unless supplied_dates == required_dates.sort

      total_bytes = 0
      rows_seen = 0
      supplied_dates.each_with_object({}) do |requested_date, parsed|
        body = @statements.fetch(requested_date)
        invalid_data! unless body.is_a?(String) && body.bytesize <= MAX_STATEMENT_BYTES
        total_bytes += body.bytesize
        invalid_data! if total_bytes > MAX_TOTAL_STATEMENT_BYTES

        statement = parse_statement(requested_date, body, orders)
        rows_seen += statement.row_count
        invalid_data! if rows_seen > MAX_CSV_ROWS
        parsed[requested_date] = statement
      end.freeze
    end

    def required_statement_dates(orders)
      months = {}
      orders.each_value { |order| add_statement_months(months, order.placement_date, order.event_date) }
      months.keys.sort
    end

    def add_statement_months(months, from_date, to_date)
      month = Date.new(from_date.year, from_date.month, 1)
      last_month = Date.new(to_date.year, to_date.month, 1)
      while month <= last_month
        month_end = Date.new(month.year, month.month, -1)
        requested_date = [ month_end, @coverage_end ].min
        months[requested_date] = true
        month = month >> 1
      end
    end

    def parse_statement(requested_date, body, orders)
      text = decode_statement(body)
      rows = CSV.parse(text, col_sep: ";", row_sep: :auto, skip_blanks: true).map do |row|
        invalid_data! unless row.is_a?(Array) && row.length <= CSV_HEADER.length
        row.map { |cell| cell.nil? ? "" : cell }
      end
      rows = rows.reject { |row| row.all? { |cell| cell.nil? || cell.strip.empty? } }
      invalid_data! unless rows.length >= 3 && rows.length <= MAX_CSV_ROWS + 3

      owner_row, period_row, header = rows.first(3)
      invalid_data! unless owner_row.length == 3
      required_string(owner_row[0], max_bytes: MAX_TEXT_BYTES)
      italian_date(owner_row[1])
      invalid_data! unless /\A(?:[01]?\d|2[0-3]):[0-5]\d:[0-5]\d\z/.match?(owner_row[2].strip)
      period_from, period_to = parse_period_row(period_row)
      expected_from = Date.new(requested_date.year, requested_date.month, 1)
      incomplete! unless period_from == expected_from && period_to == requested_date
      invalid_data! unless normalize_header(header) == CSV_HEADER

      trade_rows = rows.drop(3).filter_map do |cells|
        invalid_data! unless cells.length == CSV_HEADER.length && cells.all? { |cell| cell.is_a?(String) && cell.bytesize <= MAX_TEXT_BYTES }
        parse_statement_row(cells, period_from:, period_to:, orders:)
      end

      Statement.new(
        requested_date: requested_date,
        from_date: period_from,
        to_date: period_to,
        trade_rows: trade_rows.freeze,
        row_count: rows.length - 3
      )
    end

    def decode_statement(body)
      if body.encoding == Encoding::UTF_8
        invalid_data! unless body.valid_encoding?
        text = body.dup
      else
        text = body.dup.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
      end
      invalid_data! if text.match?(CONTROL_PATTERN)

      text
    end

    def parse_period_row(row)
      invalid_data! unless row.length == 4
      labels = row.map { |value| value.gsub(/\s+/, " ").strip }
      invalid_data! unless labels[0] == "Estratto Conto dal" && labels[2] == "al"

      from_date = italian_date(labels[1])
      to_date = italian_date(labels[3])
      invalid_data! unless from_date <= to_date
      [ from_date, to_date ]
    end

    def normalize_header(header)
      header.map { |cell| cell.nil? ? "" : cell.strip }
    end

    def parse_statement_row(cells, period_from:, period_to:, orders:)
      raw_reference = cells[3].strip
      reference = raw_reference.presence
      has_trade_fields = cells[5].strip.present? || cells[6].strip.present?
      trade_like_reference = reference&.match?(REFERENCE_PATTERN)
      known_order = reference && orders[reference]

      return if reference.nil? && !has_trade_fields
      return if !known_order && !has_trade_fields && !trade_like_reference

      date = italian_date(cells[0])
      italian_date(cells[1])
      invalid_data! unless date.between?(period_from, period_to)
      return if !known_order && !date.between?(@coverage_start, @coverage_end)
      incomplete! unless known_order

      incomplete! if cells[4].strip.blank? || cells[5].strip.blank? || cells[6].strip.blank? || cells[7].strip.blank?

      currency = cells[5].strip
      invalid_data! unless currency.match?(CURRENCY_PATTERN)
      quantity = signed_integer(cells[6])
      incomplete! if quantity.zero?
      quote_price = italian_decimal(cells[4])
      invalid_data! unless quote_price.positive?
      gross_eur = italian_decimal(cells[7])
      invalid_data! if gross_eur.zero?
      commission_reported = cells[8].strip.present?
      commission_eur = commission_reported ? italian_decimal(cells[8]) : BigDecimal("0")
      incomplete! if commission_eur.positive?
      invalid_data! unless fits_database_decimal?(gross_eur, precision: 19, scale: 4)
      invalid_data! unless fits_database_decimal?(commission_eur, precision: 19, scale: 4)

      TradeRow.new(
        date: date,
        value_date: italian_date(cells[1]),
        reference: reference.freeze,
        quote_price: quote_price,
        quote_price_text: cells[4].strip.freeze,
        currency: currency.freeze,
        quantity: BigDecimal(quantity.to_s),
        gross_eur: gross_eur,
        commission_eur: commission_eur,
        commission_reported: commission_reported
      )
    end

    def match_statement_rows(statements, orders)
      rows_by_reference = Hash.new { |hash, key| hash[key] = [] }
      statements.each_value do |statement|
        statement.trade_rows.each { |row| rows_by_reference[row.reference] << row }
      end

      orders.each do |reference, order|
        rows = rows_by_reference[reference]
        incomplete! if rows.empty?
        validate_order_rows!(order, rows)
      end
      rows_by_reference.each_key { |reference| incomplete! unless orders.key?(reference) }
      rows_by_reference.transform_values(&:freeze).freeze
    end

    def validate_order_rows!(order, rows)
      rows.each do |row|
        incomplete! unless row.reference == order.reference && row.currency == order.currency
        incomplete! unless row.date.between?(order.placement_date, order.event_date)
        expected_sign = order.side == "C" ? 1 : -1
        incomplete! unless row.quantity.positive? == expected_sign.positive?
        incomplete! unless row.gross_eur.negative? == expected_sign.positive?
      end

      signed_quantity = rows.sum(BigDecimal("0"), &:quantity)
      incomplete! unless signed_quantity == order.signed_quantity
      incomplete! unless rows.map(&:date).max == order.event_date

      weighted_quote_total = rows.sum(BigDecimal("0")) { |row| row.quantity.abs * row.quote_price }
      expected_quote_total = order.quantity * order.average_price
      tolerance = BigDecimal("0.01") * rows.length
      incomplete! if (weighted_quote_total - expected_quote_total).abs > tolerance
    end

    def build_activities(rows_by_reference, orders)
      activities = []
      rows_by_reference.each do |reference, rows|
        order = orders.fetch(reference)
        rows.group_by(&:date).each do |date, day_rows|
          next unless date.between?(@coverage_start, @coverage_end)

          activities << build_activity(order, day_rows, date)
        end
      end
      activities.sort_by { |activity| [ activity.date, activity.external_id ] }.freeze
    end

    def build_activity(order, rows, date)
      quantity = rows.sum(BigDecimal("0"), &:quantity)
      gross_eur = rows.sum(BigDecimal("0"), &:gross_eur)
      commission_eur = rows.sum(BigDecimal("0"), &:commission_eur)
      fee = commission_eur.abs
      amount = -(gross_eur + commission_eur)
      absolute_quantity = quantity.abs
      price = (gross_eur.abs / absolute_quantity).round(10)

      invalid_data! unless fits_database_decimal?(quantity, precision: 34, scale: 18)
      invalid_data! unless fits_database_decimal?(gross_eur, precision: 19, scale: 4)
      invalid_data! unless price.positive?
      invalid_data! unless fits_database_decimal?(price, precision: 19, scale: 10)
      invalid_data! unless fits_database_decimal?(amount, precision: 19, scale: 4)
      invalid_data! unless fits_database_decimal?(fee, precision: 19, scale: 4)

      order_reference_hash = Digest::SHA256.hexdigest(order.reference)
      external_id = "directa-history-v1:#{scoped_activity_id(order.reference, date)}"
      value_dates = rows.map { |row| row.value_date.iso8601 }.sort.map(&:freeze).freeze
      original_prices = rows.sort_by { |row| canonical_fill_sort_key(row) }.map(&:quote_price_text).freeze
      metadata = {
        "original_prices" => original_prices,
        "quote_currency" => order.currency,
        "value_dates" => value_dates,
        "order_ref_hash" => order_reference_hash,
        "fill_count" => rows.length,
        "aggregation" => "executed_order_day",
        "gross_eur" => decimal_string(gross_eur).freeze,
        "fee_eur" => decimal_string(fee).freeze,
        "commission_reported" => rows.all?(&:commission_reported),
        "commission_reported_fill_count" => rows.count(&:commission_reported),
        "fee_scope" => "reported_statement_commission_only"
      }.freeze
      fingerprint = activity_fingerprint(
        date: date,
        isin: order.isin,
        name: order.name,
        quantity: quantity,
        price: price,
        amount: amount,
        fee: fee,
        order_reference_hash: order_reference_hash,
        metadata: metadata
      )

      Activity.new(
        date: date,
        isin: order.isin,
        name: order.name,
        quantity: quantity,
        price: price,
        amount: amount,
        fee: fee,
        currency: "EUR".freeze,
        external_id: external_id.freeze,
        fingerprint: fingerprint.freeze,
        occurrence: 1,
        metadata: metadata
      )
    end

    def activity_fingerprint(date:, isin:, name:, quantity:, price:, amount:, fee:, order_reference_hash:, metadata:)
      fields = [
        @bank_scope,
        order_reference_hash,
        date.iso8601,
        isin,
        name,
        decimal_string(quantity),
        decimal_string(price),
        decimal_string(amount),
        decimal_string(fee),
        "EUR",
        metadata.fetch("quote_currency"),
        metadata.fetch("value_dates"),
        metadata.fetch("original_prices").map { |price_text| decimal_string(italian_decimal(price_text)) },
        metadata.fetch("fill_count"),
        metadata.fetch("gross_eur"),
        metadata.fetch("fee_eur"),
        metadata.fetch("commission_reported"),
        metadata.fetch("commission_reported_fill_count")
      ]
      Digest::SHA256.hexdigest(JSON.generate(fields))
    end

    def canonical_fill_sort_key(row)
      [
        row.value_date.iso8601,
        decimal_string(row.quantity),
        decimal_string(row.quote_price),
        decimal_string(row.gross_eur),
        decimal_string(row.commission_eur),
        row.commission_reported ? "1" : "0"
      ]
    end

    def scoped_activity_id(reference, date)
      Digest::SHA256.hexdigest(JSON.generate([ @bank_scope, reference, date.iso8601 ]))
    end

    def build_cohorts(activities)
      cohorts = Hash.new { |hash, date| hash[date] = Hash.new(0) }
      activities.each { |activity| cohorts[activity.date.iso8601][activity.fingerprint] += 1 }
      cohorts.each_with_object({}) { |(date, counts), result| result[date] = counts.freeze }.freeze
    end

    def provider_decimal(value)
      invalid_data! unless value.is_a?(Integer) || value.is_a?(Float)
      decimal = Provider::Directa.parse_decimal(value)
      invalid_data! unless decimal&.finite?
      decimal
    end

    def italian_decimal(value)
      text = required_string(value, max_bytes: 64).strip
      match = ITALIAN_DECIMAL_PATTERN.match(text)
      invalid_data! unless match

      normalized = "#{match[:sign]}#{match[:whole].delete('.')}#{match[:fraction] ? ".#{match[:fraction]}" : ""}"
      decimal = Provider::Directa.parse_decimal(normalized)
      invalid_data! unless decimal&.finite?
      decimal
    end

    def positive_integer(value)
      invalid_data! unless value.is_a?(Integer) && value.positive? && value.to_s.bytesize <= 16
      value
    end

    def signed_integer(value)
      text = required_string(value, max_bytes: 64).strip
      match = ITALIAN_INTEGER_PATTERN.match(text)
      invalid_data! unless match
      integer = Integer("#{match[:sign]}#{match[:whole].delete('.')}", 10)
      invalid_data! if integer.abs.to_s.bytesize > 16
      integer
    end

    def order_date(value)
      invalid_data! unless value.is_a?(Integer) && value.to_s.bytesize == 8
      raw = value.to_s
      invalid_data! unless /\A\d{8}\z/.match?(raw)

      Date.strptime(raw, "%Y%m%d")
    rescue Date::Error
      invalid_data!
    end

    def italian_date(value)
      text = required_string(value, max_bytes: 10).strip
      match = /\A(?<day>\d{1,2})\/(?<month>\d{1,2})\/(?<year>\d{4})\z/.match(text)
      invalid_data! unless match

      Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i)
    rescue Date::Error
      invalid_data!
    end

    def required_string(value, max_bytes:)
      invalid_data! unless value.is_a?(String) && value.bytesize <= max_bytes && value.valid_encoding?
      invalid_data! if value.match?(CONTROL_PATTERN)

      value.strip
    end

    def fits_database_decimal?(value, precision:, scale:)
      return false unless value.is_a?(BigDecimal) && value.finite?
      return false unless value.round(scale) == value

      value.abs < BigDecimal("1e#{precision - scale}")
    end

    def decimal_string(value)
      value.to_s("F").sub(/(\.\d*?)0+\z/, "\\1").sub(/\.\z/, "").then { |text| text == "-0" ? "0" : text }
    end

    def invalid_data!
      raise DirectaItem::PortfolioNormalizer::Error.new(:history_invalid_data), cause: nil
    end

    def incomplete!
      raise DirectaItem::PortfolioNormalizer::Error.new(:history_incomplete), cause: nil
    end

    def unsupported_activity!
      raise DirectaItem::PortfolioNormalizer::Error.new(:history_unsupported_activity), cause: nil
    end
end
