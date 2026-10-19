class Holding::ScalableSnapshotCalculator
  def initialize(account, account_provider_id: nil, security_ids: nil)
    @account = account
    @account_provider_id = account_provider_id || account.account_providers.find_by(provider_type: "ScalableAccount")&.id
    @security_ids = security_ids
  end

  def calculate
    provider_link = @account.account_providers.find_by(id: @account_provider_id, provider_type: "ScalableAccount")
    unless provider_link&.provider&.usable_account&.id == @account.id
      raise Provider::Scalable::Error.new(:account_conflict)
    end

    projected_rows
  end

  def projected_rows
    raise Provider::Scalable::Error.new(:account_conflict) if @account_provider_id.blank?

    holdings = @account.holdings.where(account_provider_id: @account_provider_id, date: ..Date.current)
    holdings = holdings.where(security_id: @security_ids) if @security_ids

    observed = holdings.order(:date, :id).map do |holding|
      quantity = holding.qty.to_d
      amount = holding.amount.to_d
      manual_basis = quantity.positive? && holding.cost_basis_locked? &&
        holding.cost_basis_source == "manual" && !holding.cost_basis.nil?

      Holding::HoldingData.new(
        account_id: @account.id, security_id: holding.security_id, date: holding.date,
        qty: quantity, price: quantity.positive? ? amount / quantity : holding.price.to_d,
        currency: holding.currency, amount: amount,
        cost_basis: manual_basis ? holding.cost_basis : nil,
        cost_basis_unknown: !manual_basis, cost_basis_source: manual_basis ? "manual" : nil,
        cost_basis_locked: manual_basis
      )
    end

    Holding.gapfill(observed)
  end
end
