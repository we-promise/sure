# frozen_string_literal: true

# Imports a cost-basis holding for Akahu managed-fund accounts:
#   * synthetic per-fund accounts (Kernel, via PortfolioSplitter)
#   * real accounts that already are one fund (Simplicity)
#
# Sure's gains chart is computed from holdings.amount − cost_basis × qty, not
# from the balance series. Akahu reports a contribution-adjusted `returns`
# figure on each fund; per-unit cost_basis = (value − returns) / qty
# reproduces that number.
#
# Multi-fund parents and exchange-listed portfolios are left alone. Listed
# securities belong as brokerage holdings, not as a single managed-fund row.
#
# Introducing a today-only holding onto an account with reverse-calculated
# history collapses that series (no prices on earlier dates). Before the first
# holding is written we freeze existing daily balances as reconciliation
# waypoints so later Akahu pulls can update today without wiping the past.
# Subsequent syncs only refresh today's holding; set_current_balance rotates
# a new waypoint each day.
#
# Kernel's Akahu `shares` are scaled ×100 versus the real unit register
# (9,145.6786 units arrive as 914,568). When implied price is below $0.50 we
# unscale so lots match Kernel statements. `value` stays authoritative:
# price is always amount/qty so independently-rounded provider prices cannot
# book a cash residual and walk it backwards through the series.
class AkahuAccount::HoldingsProcessor
  SOURCE = "akahu"
  MAX_TICKER_LENGTH = 60
  KERNEL_UNIT_SCALE = 100
  MIN_SANE_UNIT_PRICE = BigDecimal("0.5")

  def initialize(akahu_account)
    @akahu_account = akahu_account
  end

  def process
    return unless account.present?
    return unless account.balance_type == :investment
    return unless importable?

    pin_existing_history! if account.holdings.empty?

    date = Date.current
    imported = 0

    portfolio.each do |entry|
      imported += 1 if process_holding(entry, date: date)
    rescue => e
      Rails.logger.error(
        "AkahuAccount::HoldingsProcessor - Failed to process holding for " \
        "akahu_account_id=#{akahu_account.id} error_class=#{e.class.name}"
      )
    end

    Rails.logger.info(
      "AkahuAccount::HoldingsProcessor - Imported #{imported}/#{portfolio.size} holdings " \
      "for akahu_account_id=#{akahu_account.id}"
    )

    { success: true, imported: imported, total: portfolio.size }
  end

  private

    attr_reader :akahu_account

    def account
      @account ||= akahu_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def portfolio
      @portfolio ||= begin
        payload = akahu_account.raw_payload
        meta = payload.is_a?(Hash) ? payload.with_indifferent_access[:meta] : nil
        entries = meta.is_a?(Hash) ? meta.with_indifferent_access[:portfolio] : nil
        Array(entries).select { |entry| entry.is_a?(Hash) }
      end
    end

    def importable?
      return false if portfolio.empty?
      return true if akahu_account.synthetic?
      return false if portfolio.size != 1

      portfolio.none? { |entry| entry.with_indifferent_access[:symbol].present? }
    end

    # Freeze already-materialized daily balances as reconciliation waypoints
    # the first time a holding is introduced, so missing historical prices
    # cannot walk those days to zero.
    def pin_existing_history!
      existing = account.entries.where(entryable_type: "Valuation").pluck(:date).to_set
      today = Date.current

      Balance.where(account_id: account.id).where("date < ?", today).find_each do |row|
        next if existing.include?(row.date)

        account.entries.create!(
          date: row.date,
          amount: row.balance,
          currency: row.currency,
          name: "Balance",
          entryable: Valuation.new(kind: "reconciliation")
        )
      end
    end

    def process_holding(entry, date:)
      data = entry.with_indifferent_access
      key = holding_key(data)
      return false if key.blank?

      amount = parse_decimal(data[:value])
      return false if amount.nil? || amount.zero?

      security = resolve_security(key, data)
      return false if security.nil?

      quantity = quantity_for(data, amount)
      price = amount / quantity

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: data[:currency].presence || account.currency,
        date: date,
        price: price,
        cost_basis: cost_basis_for(amount, quantity, data),
        external_id: [ SOURCE, akahu_account.account_id, key, date ].join("_"),
        source: SOURCE,
        account_provider_id: akahu_account.account_provider&.id,
        delete_future_holdings: false
      )

      true
    end

    def quantity_for(data, amount)
      shares = parse_decimal(data[:shares])
      return BigDecimal("1") if shares.nil? || shares.zero?

      implied_price = amount / shares
      implied_price < MIN_SANE_UNIT_PRICE ? shares / KERNEL_UNIT_SCALE : shares
    end

    def cost_basis_for(amount, quantity, data)
      returns = parse_decimal(data[:returns])
      return nil if returns.nil?

      implied_cost = amount - returns
      # Withdrawals of principal+gains can make remaining value smaller than
      # lifetime returns. A negative cost basis would reproduce the number
      # mathematically but looks wrong in the UI, so we skip it.
      return nil unless implied_cost.positive?

      implied_cost / quantity
    end

    def holding_key(data)
      (data[:fund_id].presence || data[:name].presence).to_s.strip
    end

    def resolve_security(key, data)
      ticker = provider_ticker(key)
      return nil if ticker.blank?

      security = Security.find_by(ticker: ticker)
      return refresh_security(security, data) if security

      Security.create!(
        ticker: ticker,
        name: security_name(data, ticker),
        logo_url: data[:logo].presence,
        offline: true,
        offline_reason: "provider_managed"
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end

    def refresh_security(security, data)
      attrs = {}
      attrs[:name] = security_name(data, security.ticker) if security.name.blank?
      attrs[:logo_url] = data[:logo] if security.logo_url.blank? && data[:logo].present?
      security.update(attrs) if attrs.any?

      security
    end

    def security_name(data, fallback)
      data[:name].to_s.strip.presence || fallback
    end

    def provider_ticker(key)
      slug = [ "AKAHU", institution_slug, key ].compact_blank.join("-")
      slug.upcase.gsub(/[^A-Z0-9]+/, "-").gsub(/-+/, "-").delete_prefix("-").delete_suffix("-").first(MAX_TICKER_LENGTH)
    end

    def institution_slug
      metadata = akahu_account.institution_metadata
      return nil unless metadata.is_a?(Hash)

      metadata.with_indifferent_access[:name].presence
    end

    def parse_decimal(value)
      case value
      when nil then nil
      when BigDecimal then value
      when Numeric then BigDecimal(value.to_s)
      else
        string = value.to_s.strip
        return nil if string.blank?

        BigDecimal(string)
      end
    rescue ArgumentError, TypeError
      nil
    end
end
