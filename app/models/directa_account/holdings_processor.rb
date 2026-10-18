class DirectaAccount::HoldingsProcessor
  def initialize(directa_account)
    @directa_account = directa_account
  end

  def process(snapshot)
    linked_account = directa_account.usable_account
    provider_link = directa_account.account_provider
    raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict) unless linked_account && provider_link

    previous_rows = latest_provider_rows(provider_link)
    @content_validator = DirectaAccount::ContentValidator.new(directa_account)
    securities = snapshot.positions.index_with { |position| security_resolver.resolve(position) }
    preflight_collisions!(snapshot, securities, provider_link)

    snapshot.positions.each do |position|
      import_position!(position, security: securities.fetch(position), account_provider: provider_link, snapshot: snapshot)
    end

    reconcile_absent_positions!(snapshot, provider_link, previous_rows)
  end

  private

    attr_reader :directa_account

    def security_resolver
      @security_resolver ||= DirectaAccount::SecurityResolver.new
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(directa_account.current_account)
    end

    def preflight_collisions!(snapshot, securities, account_provider)
      snapshot.positions.each do |position|
        security = securities.fetch(position)
        by_external_id = account_provider.holdings.find_by(external_id: position.external_id)
        if by_external_id && !compatible_provider_holding?(by_external_id, security, account_provider)
          raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
        end

        composite = account_provider.account.holdings.find_by(
          security_id: security.id,
          date: snapshot.date,
          currency: snapshot.currency
        )
        next unless composite
        next if compatible_provider_holding?(composite, security, account_provider)

        raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
      end
    end

    def compatible_provider_holding?(holding, security, account_provider)
      provider_holding = holding.account_provider_id == account_provider.id &&
        [ nil, security.id ].include?(holding.provider_security_id) &&
        (holding.security_id == security.id || (holding.security_locked? && holding.provider_security_id == security.id))

      provider_holding || @content_validator.generated_snapshot_holding?(holding)
    end

    def import_position!(position, security:, account_provider:, snapshot:)
      adopt_verified_generated_projection!(security: security, snapshot: snapshot)
      existing_for_date = account_provider.account.holdings.find_by(
        security_id: security.id,
        date: snapshot.date,
        currency: snapshot.currency
      )
      same_date_manual_lock = locked_manual_basis?(existing_for_date)
      manual_basis = prior_locked_manual_basis(
        security: security,
        snapshot: snapshot,
        account_provider: account_provider
      ) if position.quantity.to_d.positive?

      holding = import_adapter.import_holding(
        security: security,
        quantity: position.quantity,
        amount: position.market_value,
        currency: snapshot.currency,
        date: snapshot.date,
        price: position.price,
        cost_basis: position.cost_basis,
        external_id: position.external_id,
        source: "directa",
        account_provider_id: account_provider.id,
        delete_future_holdings: false
      )

      unless compatible_provider_holding?(holding, security, account_provider) && holding.external_id == position.external_id
        raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
      end

      clear_stale_provider_basis!(holding) if position.cost_basis.nil?
      if same_date_manual_lock
        # a same-date manual edit is the user's latest correction for this snapshot.
      elsif !manual_basis.nil?
        preserve_manual_basis!(holding, manual_basis)
      else
        clear_carried_manual_basis!(holding)
      end

      if holding.provider_security_id.blank?
        holding.update!(provider_security_id: security.id)
      end

      holding
    end

    def prior_locked_manual_basis(security:, snapshot:, account_provider:)
      candidate = account_provider.account.holdings
        .where(security_id: security.id, currency: snapshot.currency)
        .where("date < ?", snapshot.date)
        .order(date: :desc)
        .first
      return unless candidate&.qty&.positive? && locked_manual_basis?(candidate)

      own_provider_row = candidate.account_id == account_provider.account_id &&
        candidate.account_provider_id == account_provider.id &&
        candidate.provider_security_id == security.id
      validated_projection = @content_validator.generated_snapshot_holding?(candidate)
      return unless own_provider_row || validated_projection

      candidate.cost_basis
    end

    def locked_manual_basis?(holding)
      holding&.cost_basis_locked? && holding.cost_basis_source == "manual" && !holding.cost_basis.nil?
    end

    def preserve_manual_basis!(holding, cost_basis)
      holding.update!(cost_basis: cost_basis, cost_basis_source: "manual", cost_basis_locked: true)
    end

    def clear_carried_manual_basis!(holding)
      return unless locked_manual_basis?(holding)

      holding.update!(cost_basis: nil, cost_basis_source: nil, cost_basis_locked: false)
    end

    def adopt_verified_generated_projection!(security:, snapshot:)
      projection = directa_account.current_account.holdings.find_by(
        security_id: security.id,
        date: snapshot.date,
        currency: snapshot.currency,
        account_provider_id: nil,
        external_id: nil
      )
      return unless projection && @content_validator.generated_snapshot_holding?(projection)
      return unless projection.cost_basis_source == "calculated"

      projection.update!(cost_basis_source: "provider")
    end

    def clear_stale_provider_basis!(holding)
      return if holding.cost_basis_locked? || holding.cost_basis_source != "provider"

      holding.update!(cost_basis: nil, cost_basis_source: nil)
    end

    def latest_provider_rows(account_provider)
      previous_date = account_provider.holdings.maximum(:date)
      return [] if previous_date.nil?

      account_provider.holdings.where(date: previous_date).where("qty > 0").to_a
    end

    def reconcile_absent_positions!(snapshot, account_provider, previous_rows)
      current_identities = snapshot.positions.map { |position| [ position.isin, position.mic ] }.to_set
      account = account_provider.account

      previous_rows.each do |holding|
        provider_security = holding.provider_security || holding.security
        identity = [ provider_security.ticker.to_s.upcase, provider_security.exchange_operating_mic.to_s.upcase ]
        next if current_identities.include?(identity)
        next unless DirectaItem::PortfolioNormalizer.valid_isin?(identity.first)
        next unless Security::EXCHANGES.key?(identity.last)

        tombstone_external_id = external_id(identity.first, identity.last, snapshot.date)
        tombstone = account_provider.holdings.find_by(external_id: tombstone_external_id)
        if tombstone && !compatible_provider_holding?(tombstone, provider_security, account_provider)
          raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
        end

        composite = account.holdings.find_by(
          security_id: provider_security.id,
          date: snapshot.date,
          currency: snapshot.currency
        )
        if composite && !compatible_provider_holding?(composite, provider_security, account_provider)
          raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
        end

        imported = import_adapter.import_holding(
          security: provider_security,
          quantity: 0,
          amount: 0,
          currency: snapshot.currency,
          date: snapshot.date,
          price: holding.price,
          cost_basis: nil,
          external_id: tombstone_external_id,
          source: "directa",
          account_provider_id: account_provider.id,
          delete_future_holdings: false
        )
        unless compatible_provider_holding?(imported, provider_security, account_provider) &&
            imported.external_id == tombstone_external_id
          raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
        end

        clear_carried_manual_basis!(imported)
      end
    end

    def external_id(isin, mic, date)
      "directa-position-#{isin}-#{mic}-#{date.iso8601}"
    end
end
