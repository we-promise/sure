class DirectaAccount::ContentValidator
  def initialize(directa_account)
    @directa_account = directa_account
  end

  def validate!
    return true if compatible?

    raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
  end

  def compatible?(linked_account = directa_account.account)
    provider_link = directa_account.account_provider
    return false unless linked_account && provider_link
    return false unless linked_account.id == directa_account.account&.id
    return false unless linked_account.account_providers.where.not(id: provider_link.id).none?
    return false unless linked_account.entries.where.not(entryable_type: "Valuation").none?
    return false if unsafe_provider_holdings?(linked_account, provider_link)

    linked_account.holdings.where(account_provider_id: nil).none? do |holding|
      !generated_snapshot_holding?(holding)
    end
  end

  def generated_snapshot_holding?(holding)
    return false unless holding.account_id == directa_account.account&.id &&
      holding.account_provider_id.nil? && holding.external_id.blank? &&
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

    attr_reader :directa_account

    def unsafe_provider_holdings?(linked_account, provider_link)
      linked_account.holdings
        .where.not(account_provider_id: nil)
        .where.not(account_provider_id: provider_link.id)
        .exists?
    end

    def projected_rows
      @projected_rows ||= Holding::DirectaSnapshotCalculator.new(
        directa_account.account,
        account_provider_id: directa_account.account_provider&.id
      ).projected_rows
    end

    def persisted_decimal(value, attribute)
      return if value.nil?

      value.to_d.round(Holding.columns_hash.fetch(attribute.to_s).scale)
    end
end
