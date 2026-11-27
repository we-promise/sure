class MoomooAccount::HoldingsProcessor
  include MoomooAccount::DataHelpers

  # `date` is the day the stored positions describe.
  def initialize(moomoo_account, date: Date.current)
    @moomoo_account = moomoo_account
    @date = date
  end

  # Imports one holding per security code, in the currency the code trades in;
  # an account split by currency, only its own currency's (see
  # MoomooAccount#positions).
  # Positions Sure doesn't import (short, options, futures and the like) are
  # left out, so their value stays in cash. Holdings moomoo no longer reports
  # are closed. Returns the amount and currency of each holding imported.
  def process
    return [] unless account.present?

    importable, others = moomoo_account.positions.partition { |position| importable_position?(position) }
    log_skipped(others)

    held = importable.group_by { |position| position["code"].to_s }
    imported = held.filter_map { |code, rows| import_code(code, rows) }
    close_absent_holdings!(held)
    imported
  end

  private

    attr_reader :moomoo_account

    def account
      @account ||= moomoo_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def provider_id
      moomoo_account.account_provider&.id
    end

    # A Japanese account can hold several positions in one code.
    def import_code(code, rows)
      quantity = rows.sum(BigDecimal("0")) { |row| parse_decimal(row["qty"]) || 0 }
      values = rows.map { |row| position_value(row) }
      # Stored at zero, the holding would read as worthless.
      raise ArgumentError, "moomoo reported no market value or price" if values.any?(&:nil?)

      value = values.sum(BigDecimal("0"))
      currency = parse_currency(rows.first["currency"]) || parse_code(code)&.dig(:currency)
      raise ArgumentError, "moomoo reported no currency" unless currency

      market_price = parse_decimal(rows.first["nominal_price"])

      import_adapter.import_holding(
        security: security_for_code(code, rows.first["stock_name"], provider_row: true),
        quantity: quantity,
        amount: value,
        currency: currency,
        date: @date,
        price: market_price&.positive? ? market_price : value / quantity,
        cost_basis: cost_basis(rows, quantity),
        external_id: holding_external_id(code),
        source: "moomoo",
        account_provider_id: provider_id,
        delete_future_holdings: false
      )

      { amount: value, currency: currency }
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "MoomooAccount::HoldingsProcessor - Failed to process #{code}: #{e.message}",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { code: code, moomoo_account_id: moomoo_account.id }
      )
      nil
    end

    # A position sold off is gone from the list, or listed with nothing left.
    # Its holding in the newest snapshot would otherwise stay current and the
    # history before the sale would count it twice, so a zero for the
    # snapshot's day closes it. A code missing from a snapshot already reads
    # as zero there, so only the newest snapshot's holdings need one. A
    # holding stays open while its code is held, even if that code's import
    # just failed, and while a held code resolves to its security.
    def close_absent_holdings!(held)
      return unless provider_id && moomoo_account.source_account.raw_positions_payload.is_a?(Array)

      holdings = account.holdings.where(account_provider_id: provider_id)
      latest = holdings.maximum(:date)
      return unless latest && latest <= @date

      # A code whose security can't be found still keeps its holding open.
      held_security_ids = held.filter_map do |code, rows|
        security_for_code(code, rows.first["stock_name"], provider_row: true).id
      rescue StandardError
        nil
      end.to_set

      holdings.where(date: latest).where.not(qty: 0).includes(:security, :provider_security).find_each do |holding|
        code = code_of(holding)
        security = holding.provider_security || holding.security
        next if code.nil? || held.key?(code) || held_security_ids.include?(security.id)

        close_holding(holding, code, security)
      end
    end

    def close_holding(holding, code, security)
      import_adapter.import_holding(
        security: security,
        quantity: 0,
        amount: 0,
        currency: holding.currency,
        date: @date,
        price: holding.price,
        cost_basis: nil,
        external_id: holding_external_id(code),
        source: "moomoo",
        account_provider_id: provider_id,
        delete_future_holdings: false
      )
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "MoomooAccount::HoldingsProcessor - Failed to close #{code}: #{e.message}",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { code: code, moomoo_account_id: moomoo_account.id }
      )
    end

    def holding_external_id(code)
      "#{holding_external_id_prefix}#{code}_#{@date}"
    end

    # The moomoo code a holding was imported for, from its external id.
    def code_of(holding)
      suffix = "_#{holding.date}"
      external_id = holding.external_id.to_s
      return nil unless external_id.start_with?(holding_external_id_prefix) && external_id.end_with?(suffix)

      external_id.delete_prefix(holding_external_id_prefix).delete_suffix(suffix).presence
    end

    # cost_price is moomoo's "diluted" cost: sells (and in Singapore cash
    # dividends) are taken off it, so it is not the average cost per share
    # that Sure measures gains against. moomoo states unrealized_pl against
    # the average cost, so the average is what market value less that leaves.
    # Without it the basis is left unknown and Sure averages the buys.
    def cost_basis(rows, quantity)
      return nil unless rows.all? { |row| row["cost_price_valid"] == true }

      cost = BigDecimal("0")
      rows.each do |row|
        value = parse_decimal(row["market_val"])
        unrealized = parse_decimal(row["unrealized_pl"])
        return nil if value.nil? || unrealized.nil?

        cost += value - unrealized
      end

      basis = cost / quantity
      basis.positive? ? basis : nil
    end

    # A position with nothing left (sold out today) is not a skip: its holding
    # is closed.
    def log_skipped(positions)
      reasons = positions.filter_map { |position| skip_reason(position) }.tally
      return if reasons.empty?

      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "MoomooAccount::HoldingsProcessor - skipped #{reasons.values.sum} positions (short, option, futures or unknown market)",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { reasons: reasons, moomoo_account_id: moomoo_account.id }
      )
    end

    def skip_reason(position)
      return nil unless parse_decimal(position["qty"])&.positive?
      return position["position_side"].to_s.downcase if position["position_side"].present? && position["position_side"] != "LONG"
      return position["security_type"].to_s.downcase if position["security_type"].present?

      "unknown_market"
    end
end
