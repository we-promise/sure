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
    return false unless directa_account.usable_account&.id == linked_account.id
    return false unless linked_account.account_providers.where.not(id: provider_link.id).none?
    return false if unsafe_entries?(linked_account)
    return false if unsafe_provider_holdings?(linked_account, provider_link)

    linked_account.holdings.where(account_provider_id: nil).none? do |holding|
      !generated_snapshot_holding?(holding)
    end
  end

  def owned_history_entry?(entry)
    return false unless entry&.account_id == directa_account.account&.id &&
      entry.entryable_type == "Trade" && entry.source == "directa" &&
      directa_account.usable_account&.id == entry.account_id

    trade = entry.entryable
    return false unless trade.is_a?(Trade) && trade.directa_history_entry?(entry)

    provider_link = directa_account.account_provider
    return false unless provider_link&.provider_type == "DirectaAccount" &&
      provider_link.provider_id == directa_account.id && provider_link.account_id == entry.account_id

    ledger = valid_history_ledger
    return false unless ledger

    metadata = trade.extra.fetch("directa")
    return false unless metadata["provider_account_id"] == directa_account.id.to_s &&
      metadata["bank_scope"] == ledger.fetch("bank_scope")

    ledger_entry = ledger.fetch("entries")[entry.external_id]
    return false unless ledger_entry.is_a?(Hash)

    fingerprint = ledger_entry["fingerprint"]
    ledger_date = strict_history_date(ledger_entry["date"])
    return false unless fingerprint == metadata["fingerprint"] && ledger_date
    return false unless ledger_date.between?(ledger.fetch("coverage_start"), ledger.fetch("coverage_end"))

    day_cohort = ledger.fetch("cohorts")[ledger_date.iso8601]
    count = day_cohort.is_a?(Hash) ? day_cohort[fingerprint] : nil
    count.is_a?(Integer) && count.positive?
  end

  def generated_snapshot_holding?(holding, projected_rows: nil)
    locked_manual_basis = holding.cost_basis_locked? && holding.cost_basis_source == "manual"
    return false unless holding.account_id == directa_account.account&.id &&
      holding.account_provider_id.nil? && holding.external_id.blank? &&
      !holding.security_locked? && (!holding.cost_basis_locked? || locked_manual_basis) &&
      ([ nil, "calculated", "provider" ].include?(holding.cost_basis_source) || locked_manual_basis)

    projection = (projected_rows || self.projected_rows).find do |row|
      row.date == holding.date && row.security_id == holding.security_id && row.currency == holding.currency
    end
    return false unless projection

    # a reimport can refresh or clear broker basis while the projected position stays the same.
    projection_matches = persisted_decimal(projection.qty, :qty) == holding.qty.to_d &&
      persisted_decimal(projection.amount, :amount) == holding.amount.to_d &&
      persisted_decimal(projection.price, :price) == holding.price.to_d &&
      persisted_decimal(projection.cost_basis, :cost_basis) == holding.cost_basis&.to_d

    return projection_core_matches?(projection, holding) if locked_manual_basis

    projection_matches || (projection_core_matches?(projection, holding) &&
      %w[calculated provider].include?(holding.cost_basis_source))
  end

  private

    attr_reader :directa_account

    def unsafe_provider_holdings?(linked_account, provider_link)
      linked_account.holdings
        .where.not(account_provider_id: nil)
        .where.not(account_provider_id: provider_link.id)
        .exists?
    end

    def unsafe_entries?(linked_account)
      linked_account.entries
        .where("entries.entryable_type IS NULL OR entries.entryable_type <> ?", "Valuation")
        .includes(:entryable)
        .any? { |entry| !owned_history_entry?(entry) }
    end

    def valid_history_ledger
      return @valid_history_ledger if defined?(@valid_history_ledger)

      ledger = directa_account.history_ledger
      return @valid_history_ledger = nil unless ledger.is_a?(Hash)
      return @valid_history_ledger = nil unless ledger["schema_version"].instance_of?(Integer) && ledger["schema_version"] == 1
      return @valid_history_ledger = nil unless ledger["bank_scope"].is_a?(String) && ledger["bank_scope"].match?(Trade::DIRECTA_HISTORY_BANK_SCOPE_PATTERN)

      coverage_start = strict_history_date(ledger["coverage_start"])
      coverage_end = strict_history_date(ledger["coverage_end"])
      return @valid_history_ledger = nil unless coverage_start && coverage_end && coverage_start <= coverage_end
      return @valid_history_ledger = nil unless ledger["entries"].is_a?(Hash) && ledger["cohorts"].is_a?(Hash)

      @valid_history_ledger = ledger.merge(
        "coverage_start" => coverage_start,
        "coverage_end" => coverage_end
      )
    end

    def strict_history_date(value)
      return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      date = Date.iso8601(value)
      date if date.iso8601 == value
    rescue Date::Error
      nil
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

    def projection_core_matches?(projection, holding)
      persisted_decimal(projection.qty, :qty) == holding.qty.to_d &&
        persisted_decimal(projection.amount, :amount) == holding.amount.to_d &&
        persisted_decimal(projection.price, :price) == holding.price.to_d
    end
end
