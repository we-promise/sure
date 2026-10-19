require "digest"

class ScalableAccount::HoldingsProcessor
  def initialize(scalable_account)
    @scalable_account = scalable_account
  end

  def process(portfolio)
    account = @scalable_account.usable_account
    account_provider = @scalable_account.account_provider
    raise Provider::Scalable::Error.new(:account_conflict) unless account && account_provider

    previous_date = account_provider.holdings.maximum(:date)
    previous_rows = if previous_date
      account_provider.holdings.where(date: previous_date).where("qty > 0").to_a
    else
      []
    end
    securities = portfolio.positions.index_with { |position| security_resolver.resolve(position) }
    @content_validator = ScalableAccount::ContentValidator.new(@scalable_account)
    raise Provider::Scalable::Error.new(:account_conflict) unless @content_validator.compatible?(account)
    preflight_collisions!(portfolio, securities, account_provider, account)
    portfolio.positions.each do |position|
      import_position!(
        position,
        security: securities.fetch(position),
        account_provider: account_provider,
        account: account,
        portfolio: portfolio
      )
    end
    reconcile_absent_positions!(portfolio, account_provider, account, previous_rows: previous_rows)
  rescue Provider::Scalable::Error
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound
    raise Provider::Scalable::Error.new(:account_conflict), cause: nil
  end

  private

    def security_resolver
      @security_resolver ||= ScalableAccount::SecurityResolver.new
    end

    def preflight_collisions!(portfolio, securities, account_provider, account)
      portfolio.positions.each do |position|
        security = securities.fetch(position)
        id = external_id(position.isin, portfolio.observed_at.utc.to_date)
        by_external_id = account_provider.holdings.find_by(external_id: id)
        raise Provider::Scalable::Error.new(:account_conflict) if by_external_id && !compatible?(by_external_id, security, account_provider)

        composite = account.holdings.find_by(
          security_id: security.id,
          date: portfolio.observed_at.utc.to_date,
          currency: portfolio.currency
        )
        next unless composite
        next if compatible?(composite, security, account_provider) ||
          @content_validator.generated_snapshot_holding?(composite, account)

        raise Provider::Scalable::Error.new(:account_conflict)
      end
    end

    def import_position!(position, security:, account_provider:, account:, portfolio:)
      date = portfolio.observed_at.utc.to_date
      holding = import_adapter(account).import_holding(
        security: security,
        quantity: position.quantity,
        amount: position.valuation,
        currency: position.currency,
        date: date,
        price: position.unit_price,
        cost_basis: nil,
        external_id: external_id(position.isin, date),
        source: "scalable",
        account_provider_id: account_provider.id,
        delete_future_holdings: false
      )

      unless compatible?(holding, security, account_provider)
        raise Provider::Scalable::Error.new(:account_conflict)
      end
      holding.update!(provider_security_id: security.id) if holding.provider_security_id.blank?
      holding
    end

    def reconcile_absent_positions!(portfolio, account_provider, account, previous_rows:)
      return if previous_rows.empty?

      current_isins = portfolio.positions.map(&:isin).to_set
      date = portfolio.observed_at.utc.to_date

      previous_rows.each do |holding|
        security = holding.provider_security || holding.security
        isin = security.ticker.to_s.upcase
        next if current_isins.include?(isin)
        raise Provider::Scalable::Error.new(:account_conflict) unless ScalableItem::PortfolioNormalizer.valid_isin?(isin)

        tombstone_id = external_id(isin, date)
        by_external_id = account_provider.holdings.find_by(external_id: tombstone_id)
        raise Provider::Scalable::Error.new(:account_conflict) if by_external_id && !compatible?(by_external_id, security, account_provider)

        composite = account.holdings.find_by(security_id: security.id, date: date, currency: portfolio.currency)
        if composite && !compatible?(composite, security, account_provider) &&
            !@content_validator.generated_snapshot_holding?(composite, account)
          raise Provider::Scalable::Error.new(:account_conflict)
        end

        tombstone = import_adapter(account).import_holding(
          security: security,
          quantity: 0,
          amount: 0,
          currency: portfolio.currency,
          date: date,
          price: holding.price || BigDecimal("0"),
          cost_basis: nil,
          external_id: tombstone_id,
          source: "scalable",
          account_provider_id: account_provider.id,
          delete_future_holdings: false
        )
        raise Provider::Scalable::Error.new(:account_conflict) unless compatible?(tombstone, security, account_provider)

        tombstone.update!(provider_security_id: security.id) if tombstone.provider_security_id.blank?
      end
    end

    def compatible?(holding, security, account_provider)
      holding.account_provider_id == account_provider.id &&
        [ nil, security.id ].include?(holding.provider_security_id) &&
        (holding.security_id == security.id || (holding.security_locked? && holding.provider_security_id == security.id))
    end

    def external_id(isin, date)
      scope = Digest::SHA256.hexdigest("#{@scalable_account.uid}\0#{isin}")
      "scalable-position-#{scope}-#{date.iso8601}"
    end

    def import_adapter(account)
      Account::ProviderImportAdapter.new(account)
    end
end
