class Holding::DirectaSnapshotCalculator
  def initialize(account, account_provider_id:, security_ids: nil)
    @account = account
    @account_provider_id = account_provider_id
    @security_ids = security_ids
  end

  def calculate
    directa_account = account.account_providers.find_by(provider_type: "DirectaAccount")&.provider
    unless directa_account && directa_account.account_provider&.id == account_provider_id
      raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
    end

    DirectaAccount::ContentValidator.new(directa_account).validate!
    build_projected_rows
  end

  def projected_rows
    build_projected_rows
  end

  private

    attr_reader :account, :account_provider_id, :security_ids

    def build_projected_rows
      provider_rows = account.holdings
        .where(account_provider_id: account_provider_id)
        .where(date: ..Date.current)
      provider_rows = provider_rows.where(security_id: security_ids) if security_ids

      observed = provider_rows.order(:date, :id).map do |holding|
        quantity = holding.qty.to_d
        amount = holding.amount.to_d
        price = quantity.positive? ? amount / quantity : holding.price.to_d

        Holding::HoldingData.new(
          account_id: account.id,
          security_id: holding.security_id,
          date: holding.date,
          qty: quantity,
          price: price,
          currency: holding.currency,
          amount: amount,
          cost_basis: holding.cost_basis,
          cost_basis_unknown: false
        )
      end

      Holding.gapfill(observed)
    end
end
