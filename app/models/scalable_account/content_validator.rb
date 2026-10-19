class ScalableAccount::ContentValidator
  def initialize(scalable_account)
    @scalable_account = scalable_account
    @projected_rows_by_security = {}
  end

  def compatible?(account = @scalable_account.current_account)
    return false unless account && @scalable_account.account_provider
    return false if account.holdings.where.not(account_provider_id: nil)
      .where.not(account_provider_id: @scalable_account.account_provider.id).exists?
    return false if account.holdings.where(account_provider_id: nil).where.not(external_id: nil).exists?

    unowned_rows(account).all? { |holding| generated_snapshot_holding?(holding, account) }
  rescue Provider::Scalable::Error, ActiveRecord::RecordNotFound
    false
  end

  def generated_snapshot_holding?(holding, account = @scalable_account.current_account)
    return false unless account && holding.account_provider_id.nil? && holding.external_id.nil?
    return false if holding.security_locked? || holding.cost_basis_locked? || holding.cost_basis_source == "manual"

    projected_rows_for(account, holding.security_id).any? do |projected|
      projected.account_id == account.id &&
        projected.security_id == holding.security_id &&
        projected.date == holding.date &&
        projected.currency == holding.currency &&
        persisted_decimal(projected.qty, :qty) == holding.qty.to_d &&
        persisted_decimal(projected.amount, :amount) == holding.amount.to_d &&
        persisted_decimal(projected.price, :price) == holding.price.to_d
    end
  rescue Provider::Scalable::Error, ActiveRecord::RecordNotFound
    false
  end

  private

    def unowned_rows(account)
      account.holdings.where(account_provider_id: nil, external_id: nil).to_a
    end

    def projected_rows_for(account, security_id)
      @projected_rows_by_security[security_id] ||= Holding::ScalableSnapshotCalculator.new(
        account,
        account_provider_id: @scalable_account.account_provider.id,
        security_ids: [ security_id ]
      ).projected_rows
    end

    def persisted_decimal(value, attribute)
      return if value.nil?

      value.to_d.round(Holding.columns_hash.fetch(attribute.to_s).scale)
    end
end
