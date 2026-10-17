class FinecoAccount::ContentValidator
  def initialize(account, fineco_account)
    @account = account
    @fineco_account = fineco_account
  end

  def validate!
    return true unless unsafe_entries? || unsafe_valuations? || unsafe_provider_holdings? || unsafe_unowned_holdings?

    raise FinecoItem::PortfolioImportError.new(:account_content_conflict)
  end

  def generated_snapshot_holding?(holding)
    return false unless holding.account_provider_id.nil? && holding.external_id.blank? &&
      !holding.security_locked? && !holding.cost_basis_locked? &&
      [ nil, "calculated" ].include?(holding.cost_basis_source)

    projection = projected_rows.find do |row|
      row.date == holding.date && row.security_id == holding.security_id && row.currency == holding.currency
    end
    return false unless projection

    persisted_decimal(projection.qty, :qty) == holding.qty.to_d &&
      persisted_decimal(projection.amount, :amount) == holding.amount.to_d &&
      persisted_decimal(projection.price, :price) == holding.price.to_d &&
      persisted_decimal(projection.cost_basis, :cost_basis) == holding.cost_basis&.to_d
  end

  private
    attr_reader :account, :fineco_account

    def account_provider_id
      fineco_account.account_provider&.id
    end

    def provider_holdings
      account.holdings.where(account_provider_id: account_provider_id)
    end

    def unsafe_entries?
      owned_history_entry_ids = Trade.fineco_history
        .where("trades.extra #>> '{fineco,provider_account_id}' = ?", fineco_account.id)
        .select("entries.id")

      account.entries
        .where.not(entryable_type: "Valuation")
        .where.not(id: owned_history_entry_ids)
        .exists?
    end

    def unsafe_valuations?
      return false unless account.valuations.exists?

      totals = provider_holdings.group(:date).sum(:amount)
      if fineco_account.last_snapshot_date
        totals[fineco_account.last_snapshot_date] ||= BigDecimal("0")
      end
      first_snapshot_date = totals.keys.min

      account.valuations.includes(:entry).any? do |valuation|
        entry = valuation.entry
        next true unless entry && !entry.user_modified? && entry.locked_attributes.blank?
        next entry.amount.to_d.nonzero? || (first_snapshot_date && entry.date >= first_snapshot_date) if valuation.opening_anchor?

        total = totals[entry.date]
        if total.nil? && entry.amount.to_d.zero?
          next false
        end

        total.nil? || total.to_d != entry.amount.to_d || entry.currency != account.currency
      end
    end

    def unsafe_provider_holdings?
      return false if account_provider_id.nil?

      account.holdings
        .where.not(account_provider_id: nil)
        .where.not(account_provider_id: account_provider_id)
        .exists?
    end

    def unsafe_unowned_holdings?
      unowned = account.holdings.where(account_provider_id: nil)
      unowned.any? { |holding| !generated_snapshot_holding?(holding) }
    end

    def projected_rows
      @projected_rows ||= Holding::FinecoSnapshotCalculator.new(
        account,
        account_provider_id: account_provider_id
      ).projected_rows
    end

    def persisted_decimal(value, attribute)
      return if value.nil?

      value.to_d.round(Holding.columns_hash.fetch(attribute.to_s).scale)
    end
end
