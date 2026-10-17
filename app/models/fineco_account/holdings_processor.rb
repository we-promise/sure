class FinecoAccount::HoldingsProcessor
  POSITION_EXTERNAL_ID = /\Afineco-position-([A-Z0-9]{12})-([A-Z0-9]{4})-\d{4}-\d{2}-\d{2}\z/

  def initialize(fineco_account)
    @fineco_account = fineco_account
  end

  def process(snapshot)
    account = @fineco_account.current_account
    account_provider = @fineco_account.account_provider
    raise FinecoItem::PortfolioImportError.new(:account_conflict) unless account && account_provider

    @content_validator = FinecoAccount::ContentValidator.new(account, @fineco_account)
    security_resolver = FinecoAccount::SecurityResolver.new
    securities = snapshot.positions.index_with { |position| security_resolver.resolve(position) }
    effective_securities = preflight_collisions!(snapshot, securities, account_provider)
    @content_validator.validate!

    snapshot.positions.each do |position|
      import_position!(
        position,
        security: securities.fetch(position),
        effective_security: effective_securities.fetch(position),
        account_provider: account_provider,
        snapshot: snapshot
      )
    end

    reconcile_absent_positions!(snapshot, account, account_provider)
    persist_position_metadata!(snapshot)
  end

  private

    def preflight_collisions!(snapshot, securities, account_provider)
      account = @fineco_account.current_account
      destination_ids = {}
      effective_securities = {}

      snapshot.positions.each do |position|
        provider_security = securities.fetch(position)
        id = external_id(position.isin, position.mic, snapshot.date)
        effective_security = effective_security_for(
          provider_security,
          snapshot,
          account_provider,
          id
        )

        if destination_ids.key?(effective_security.id) && destination_ids[effective_security.id] != id
          raise FinecoItem::PortfolioImportError.new(:holding_conflict)
        end
        destination_ids[effective_security.id] = id
        effective_securities[position] = effective_security

        preflight_import_collision!(
          account,
          provider_security: provider_security,
          effective_security: effective_security,
          date: snapshot.date,
          currency: snapshot.currency,
          external_id: id,
          account_provider: account_provider
        )
      end

      effective_securities
    end

    def effective_security_for(provider_security, snapshot, account_provider, id)
      existing = @fineco_account.current_account.holdings.find_by(external_id: id)
      return existing.security if existing&.security_locked?
      return provider_security if existing.present?

      previous = @fineco_account.current_account.holdings
        .where(account_provider_id: account_provider.id, currency: snapshot.currency)
        .where("holdings.date < ?", snapshot.date)
        .where(
          "holdings.provider_security_id = :id OR (holdings.provider_security_id IS NULL AND holdings.security_id = :id)",
          id: provider_security.id
        )
        .order(date: :desc)
        .first

      previous&.security_locked? ? previous.security : provider_security
    end

    def preflight_import_collision!(account, provider_security:, effective_security:, date:, currency:, external_id:, account_provider:)
      existing_by_id = account.holdings.find_by(external_id: external_id)
      if existing_by_id && existing_by_id.account_provider_id != account_provider.id
        raise FinecoItem::PortfolioImportError.new(:holding_conflict)
      end

      provider_security_ids = Security.where("UPPER(ticker) = ?", provider_security.ticker.to_s.upcase).pluck(:id)
      collisions = account.holdings
        .where(date: date, currency: currency)
        .where("holdings.security_id = :effective_id OR holdings.provider_security_id IN (:provider_ids)",
               effective_id: effective_security.id, provider_ids: provider_security_ids)
        .where("holdings.external_id IS DISTINCT FROM ?", external_id)
        .to_a
      if collisions.any? { |holding| !adoptable_calculated_holding?(holding) }
        raise FinecoItem::PortfolioImportError.new(:holding_conflict)
      end
    end

    def adoptable_calculated_holding?(holding)
      @content_validator.generated_snapshot_holding?(holding)
    end

    def import_position!(position, security:, effective_security:, account_provider:, snapshot:)
      import_snapshot_holding!(
        account: @fineco_account.current_account,
        security: security,
        effective_security: effective_security,
        quantity: position.quantity,
        amount: position.market_value,
        currency: snapshot.currency,
        date: snapshot.date,
        price: position.effective_price,
        cost_basis: position.cost_basis,
        external_id: external_id(position.isin, position.mic, snapshot.date),
        account_provider: account_provider
      )
    end

    def import_snapshot_holding!(account:, security:, effective_security:, quantity:, amount:, currency:, date:, price:, cost_basis:, external_id:, account_provider:)
      remove_calculated_target_row!(account, effective_security, date, currency) if effective_security.id != security.id

      holding = Account::ProviderImportAdapter.new(account).import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: currency,
        date: date,
        price: price,
        cost_basis: cost_basis,
        external_id: external_id,
        source: "fineco",
        account_provider_id: account_provider.id,
        delete_future_holdings: false
      )

      unless holding.account_provider_id == account_provider.id && holding.external_id == external_id &&
             holding.security_id == effective_security.id &&
             [ nil, security.id ].include?(holding.provider_security_id)
        raise FinecoItem::PortfolioImportError.new(:holding_conflict)
      end

      if holding.provider_security_id.blank?
        holding.update!(
          provider_security_id: security.id,
          security_locked: holding.security_locked? || effective_security.id != security.id
        )
      end

      holding
    end

    def remove_calculated_target_row!(account, effective_security, date, currency)
      rows = account.holdings.where(
        account_provider_id: nil,
        external_id: nil,
        security_id: effective_security.id,
        date: date,
        currency: currency,
        security_locked: false,
        cost_basis_locked: false
      ).to_a.select { |holding| @content_validator.generated_snapshot_holding?(holding) }
      return if rows.empty?

      account.holdings.where(id: rows.map(&:id)).delete_all
    end

    def reconcile_absent_positions!(snapshot, account, account_provider)
      previous_date = @fineco_account.last_snapshot_date
      return if previous_date.nil?

      previous_rows = account.holdings
        .where(account_provider_id: account_provider.id, date: previous_date)
        .where("qty > 0")
        .to_a
      current_keys = snapshot.positions.map { |position| [ position.isin, position.mic ] }.to_set

      previous_rows.each do |holding|
        identity = identity_from_external_id(holding.external_id)
        raise FinecoItem::PortfolioImportError.new(:holding_conflict) unless identity
        next if current_keys.include?(identity)

        security = holding.provider_security || holding.security
        id = external_id(identity.first, identity.last, snapshot.date)
        effective_security = effective_security_for(
          security,
          snapshot,
          account_provider,
          id
        )
        preflight_import_collision!(
          account,
          provider_security: security,
          effective_security: effective_security,
          date: snapshot.date,
          currency: snapshot.currency,
          external_id: id,
          account_provider: account_provider
        )

        import_snapshot_holding!(
          account: account,
          security: security,
          effective_security: effective_security,
          quantity: 0,
          amount: 0,
          currency: snapshot.currency,
          date: snapshot.date,
          price: holding.price,
          cost_basis: holding.cost_basis,
          external_id: id,
          account_provider: account_provider
        )
      end
    end

    def external_id(isin, mic, date)
      "fineco-position-#{isin}-#{mic}-#{date.iso8601}"
    end

    def identity_from_external_id(value)
      match = POSITION_EXTERNAL_ID.match(value.to_s)
      match && [ match[1], match[2] ]
    end

    def persist_position_metadata!(snapshot)
      metadata = snapshot.positions.map do |position|
        {
          "isin" => position.isin,
          "mic" => position.mic,
          "quote_currency" => position.quote_currency,
          "quote_price" => position.quote_price.to_s("F"),
          "average_price" => position.average_price&.to_s("F"),
          "accrual" => position.accrual.to_s("F"),
          "ongoing_accrual" => position.ongoing_accrual.to_s("F"),
          "instrument_type" => position.instrument_type,
          "type" => position.position_type
        }.compact
      end

      @fineco_account.update!(
        raw_position_metadata: metadata,
        last_snapshot_date: snapshot.date,
        last_snapshot_at: snapshot.captured_at,
        currency: snapshot.currency
      )
    end
end
