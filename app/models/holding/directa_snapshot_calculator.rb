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
        manual_basis = quantity.positive? && holding.cost_basis_locked? &&
          holding.cost_basis_source == "manual" && !holding.cost_basis.nil?
        provider_basis = holding.cost_basis_source == "provider" && holding.cost_basis&.positive?
        cost_basis = holding.cost_basis if manual_basis || provider_basis
        cost_basis_source = manual_basis ? "manual" : ("provider" if provider_basis)

        Holding::HoldingData.new(
          account_id: account.id,
          security_id: holding.security_id,
          date: holding.date,
          qty: quantity,
          price: price,
          currency: holding.currency,
          amount: amount,
          cost_basis: cost_basis,
          cost_basis_unknown: cost_basis.nil?,
          cost_basis_source: cost_basis_source,
          cost_basis_locked: manual_basis
        )
      end

      rows = Holding.gapfill(observed)
      apply_validated_manual_basis_overrides(rows)
    end

    def apply_validated_manual_basis_overrides(rows)
      provider_account = account.account_providers.find_by(id: account_provider_id)&.provider
      return rows unless provider_account && rows.any?

      validator = DirectaAccount::ContentValidator.new(provider_account)
      first_date = rows.min_by(&:date).date
      manual_rows = account.holdings
        .where(account_provider_id: nil, external_id: nil, security_locked: false,
          cost_basis_locked: true, cost_basis_source: "manual")
        .where(date: first_date..Date.current)
        .order(:date)
      manual_overrides = manual_rows.each_with_object({}) do |holding, overrides|
        next unless validator.generated_snapshot_holding?(holding, projected_rows: rows)
        next unless holding.qty.to_d.positive? && !holding.cost_basis.nil?

        overrides[[ holding.security_id, holding.currency, holding.date ]] = holding.cost_basis
      end

      rows.group_by { |row| [ row.security_id, row.currency ] }.each_value do |security_rows|
        active_manual_basis = nil
        security_rows.sort_by(&:date).each do |row|
          if row.qty.to_d <= 0
            active_manual_basis = nil
            next
          end

          if row.cost_basis_locked && row.cost_basis_source == "manual" && !row.cost_basis.nil?
            active_manual_basis = row.cost_basis
          end
          manual_override = manual_overrides[[ row.security_id, row.currency, row.date ]]
          active_manual_basis = manual_override if manual_override
          next if active_manual_basis.nil?

          row.cost_basis = active_manual_basis
          row.cost_basis_unknown = false
          row.cost_basis_source = "manual"
          row.cost_basis_locked = true
        end
      end

      rows
    end
end
