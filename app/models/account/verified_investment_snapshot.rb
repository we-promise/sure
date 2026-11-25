class Account::VerifiedInvestmentSnapshot
  EXTERNAL_ID_PREFIX = "verified-investment:"
  ROW_CONDITION = "holdings.account_provider_id IS NULL AND holdings.external_id LIKE '#{EXTERNAL_ID_PREFIX}%'".freeze

  def initialize(account)
    @account = account
  end

  def publish!(date:, total:, cash:, positions:)
    date = Date.iso8601(date.to_s)
    total, cash = [ total, cash ].map { |value| decimal(value, 4) }
    rows = positions.map { |position| holding_attributes(position) }
    unless rows.pluck(:security_id).uniq.size == rows.size && rows.sum(0.to_d) { |row| row.fetch(:amount) } + cash == total
      raise ArgumentError, "The position values and cash must reconcile to the reported total, with one row per security"
    end

    @account.with_lock do
      unless @account.accountable_type == "Investment" && @account.account_providers.pluck(:provider_type) == [ "SimplefinAccount" ]
        raise ArgumentError, "A verified snapshot requires an investment account linked only to SimpleFIN"
      end

      prior_date = @account.verified_investment_snapshot_date
      if date > Date.current || (prior_date && date <= prior_date)
        raise ArgumentError, "The observation must be dated today or earlier and newer than the previous verified snapshot"
      end

      # The raw holdings API is a date-based history. Do not silently mix this
      # observation with a competing snapshot or overwrite any security row.
      if @account.holdings.where("holdings.date >= ?", date).exists?
        raise ArgumentError, "The account already has holdings on or after the observation date"
      end
      if @account.balances.where(currency: @account.currency).where("date >= ?", date).exists?
        raise ArgumentError, "The account already has a balance on or after the observation date"
      end

      rows.each do |row|
        @account.holdings.create!(row.merge(date: date, currency: @account.currency,
          external_id: "#{EXTERNAL_ID_PREFIX}#{date}:#{row.fetch(:security_id)}"))
      end

      # A dated close, not a transaction or a statement about that day's flows.
      @account.balances.create!(date: date, currency: @account.currency, balance: total, cash_balance: cash,
        start_cash_balance: cash, start_non_cash_balance: total - cash)
      @account.update!(verified_investment_snapshot_date: date, balance: total, cash_balance: cash)
    end
  end

  private

    def holding_attributes(position)
      qty = decimal(position.fetch(:qty), 18)
      amount = decimal(position.fetch(:amount), 4)
      price = decimal(position.fetch(:price), 4)
      raw_basis = position[:cost_basis]
      basis = decimal(raw_basis, 4) unless raw_basis.nil?
      unless qty.positive? && amount >= 0 && price >= 0 && (basis.nil? || basis >= 0)
        raise ArgumentError, "A verified position must have positive quantity and nonnegative value, price and known basis"
      end

      {
        security_id: position.fetch(:security_id), qty: qty, amount: amount, price: price,
        cost_basis: basis, cost_basis_source: ("manual" unless basis.nil?), cost_basis_locked: !basis.nil?,
        security_locked: true
      }
    end

    def decimal(value, scale)
      result = BigDecimal(value.to_s)
      raise ArgumentError, "Invalid snapshot number" unless result.finite? && result.round(scale) == result

      result
    end
end
