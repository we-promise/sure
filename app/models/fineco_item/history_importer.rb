class FinecoItem::HistoryImporter
  SOURCE = "fineco".freeze
  LEDGER_VERSION = 1
  FINGERPRINT_PATTERN = /\A[0-9a-f]{64}\z/.freeze
  EXTERNAL_ID_PATTERN = /\Afineco-history-v1:[0-9a-f]{64}\z/.freeze

  def initialize(item)
    @item = item
  end

  def import(normalized:, coverage_start:, coverage_end:)
    from_date = coverage_date(coverage_start)
    to_date = coverage_date(coverage_end)
    invalid_data! if from_date > to_date
    validate_normalized!(normalized, from_date, to_date)
    imported_count = 0
    linked_account = nil

    @item.with_lock do
      ApplicationRecord.transaction(requires_new: true) do
        provider_account = validate_provider_account!
        owner = User.find_by(id: @item.owner_id, family_id: @item.family_id)
        identity_changed! unless owner

        owner.with_lock do
          identity_changed! unless owner.active? && provider_account.reload.fineco_item_id == @item.id
          linked_account = provider_account.usable_account
          identity_changed! unless linked_account

          imported_count = import_activities!(
            provider_account: provider_account,
            account: linked_account,
            normalized: normalized,
            coverage_start: from_date,
            coverage_end: to_date
          )
        end
      end
    end

    if imported_count.positive?
      ActiveRecord.after_all_transactions_commit { linked_account.sync_later }
    end

    imported_count
  rescue FinecoItem::PortfolioImportError
    raise
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
    raise FinecoItem::PortfolioImportError.new(:history_changed), cause: nil
  end

  def inspect
    "#<#{self.class.name} [REDACTED]>"
  end

  alias to_s inspect

  private

    def validate_provider_account!
      identity_changed! unless @item.persisted? && @item.owner_id.present? && @item.family_id.present?

      provider_account = @item.fineco_account
      identity_changed! unless provider_account&.usable_account
      provider_account
    end

    def import_activities!(provider_account:, account:, normalized:, coverage_start:, coverage_end:)
      ledger = normalized_ledger(provider_account.history_ledger)
      prior_days = ledger.fetch("days")
      incoming_days = normalized.cohorts
      covered_days = (coverage_start..coverage_end).to_a

      covered_days.each do |date|
        day = date.iso8601
        old_counts = prior_days.fetch(day, {})
        new_counts = incoming_days.fetch(day, {})
        history_changed! if old_counts.any? { |fingerprint, count| new_counts.fetch(fingerprint, 0) < count }
      end

      prior_counts_by_day = covered_days.to_h do |date|
        [ date.iso8601, prior_days.fetch(date.iso8601, {}) ]
      end
      adapter = Account::ProviderImportAdapter.new(account)
      inserted = 0

      normalized.activities.each do |activity|
        day = activity.date.iso8601
        prior_count = prior_counts_by_day.fetch(day, {}).fetch(activity.fingerprint, 0)
        existing = account.entries.includes(:entryable).find_by(external_id: activity.external_id)
        if existing
          history_changed! unless existing.source == SOURCE && existing.entryable.is_a?(Trade)
          next
        end
        next if activity.occurrence <= prior_count

        security = resolve_security!(provider_account, activity)
        entry = adapter.import_trade(
          security: security,
          quantity: activity.quantity,
          price: activity.price,
          amount: activity.amount,
          currency: activity.currency,
          date: activity.date,
          name: activity.name,
          external_id: activity.external_id,
          source: SOURCE
        )
        entry.entryable.update!(extra: (entry.entryable.extra || {}).merge(
          "fineco" => trade_metadata(provider_account, activity)
        ))
        inserted += 1
      end

      days = prior_days.deep_dup
      covered_days.each do |date|
        day = date.iso8601
        days[day] = incoming_days.fetch(day, {}).deep_dup
      end

      coverage_from = [ ledger["coverage_from"], coverage_start.iso8601 ].compact.min
      coverage_to = [ ledger["coverage_to"], coverage_end.iso8601 ].compact.max
      provider_account.update!(
        history_ledger: {
          "version" => LEDGER_VERSION,
          "coverage_from" => coverage_from,
          "coverage_to" => coverage_to,
          "days" => days
        },
        history_synced_at: Time.current
      )

      inserted
    end

    def normalized_ledger(value)
      return { "days" => {} } if value.nil?
      history_changed! unless value.is_a?(Hash)

      version = value["version"] || value[:version]
      days = value["days"] || value[:days]
      history_changed! unless version == LEDGER_VERSION && days.is_a?(Hash)

      normalized_days = days.each_with_object({}) do |(day, counts), result|
        parsed_day = coverage_date(day)
        history_changed! unless parsed_day.iso8601 == day.to_s && counts.is_a?(Hash)
        result[parsed_day.iso8601] = counts.each_with_object({}) do |(fingerprint, count), normalized_counts|
          history_changed! unless fingerprint.to_s.match?(FINGERPRINT_PATTERN) && count.is_a?(Integer) && count.positive?
          normalized_counts[fingerprint.to_s] = count
        end
      end

      from = value["coverage_from"] || value[:coverage_from]
      to = value["coverage_to"] || value[:coverage_to]
      from_date = coverage_date(from)
      to_date = coverage_date(to)
      history_changed! if from_date > to_date

      { "coverage_from" => from_date.iso8601, "coverage_to" => to_date.iso8601, "days" => normalized_days }
    rescue FinecoItem::PortfolioImportError
      raise
    rescue ArgumentError, TypeError, Date::Error
      history_changed!
    end

    def validate_normalized!(normalized, coverage_start, coverage_end)
      activities = normalized.activities
      cohorts = normalized.cohorts
      invalid_data! unless activities.is_a?(Array) && cohorts.is_a?(Hash)

      expected = Hash.new { |days, day| days[day] = Hash.new(0) }
      external_ids = {}
      occurrence_groups = Hash.new { |groups, key| groups[key] = [] }
      activities.each do |activity|
        invalid_data! unless activity.respond_to?(:date) && activity.respond_to?(:fingerprint) &&
          activity.respond_to?(:occurrence) && activity.respond_to?(:external_id) &&
          activity.respond_to?(:isin) && activity.respond_to?(:quantity) && activity.respond_to?(:price) &&
          activity.respond_to?(:amount) && activity.respond_to?(:currency) && activity.respond_to?(:metadata)
        invalid_data! unless activity.date.is_a?(Date) && activity.date >= coverage_start && activity.date <= coverage_end
        invalid_data! unless activity.fingerprint.to_s.match?(FINGERPRINT_PATTERN)
        invalid_data! unless activity.occurrence.is_a?(Integer) && activity.occurrence.positive?
        invalid_data! unless activity.external_id.to_s.match?(EXTERNAL_ID_PATTERN)
        invalid_data! unless activity.isin.to_s.match?(FinecoItem::HistoryNormalizer::ISIN_PATTERN)
        invalid_data! unless activity.quantity.is_a?(BigDecimal) && activity.quantity.finite? && !activity.quantity.zero?
        invalid_data! unless activity.price.is_a?(BigDecimal) && activity.price.finite? && activity.price >= 0
        invalid_data! unless activity.amount.is_a?(BigDecimal) && activity.amount.finite? && !activity.amount.zero?
        invalid_data! unless activity.currency == "EUR" && activity.metadata.is_a?(Hash)
        invalid_data! if external_ids[activity.external_id]

        external_ids[activity.external_id] = true
        expected[activity.date.iso8601][activity.fingerprint] += 1
        occurrence_groups[[ activity.date.iso8601, activity.fingerprint ]] << activity.occurrence
      end

      occurrence_groups.each_value do |occurrences|
        invalid_data! unless occurrences.sort == (1..occurrences.length).to_a
      end
      expected = expected.transform_values(&:to_h)
      invalid_data! unless expected == cohorts
    rescue FinecoItem::PortfolioImportError
      raise
    rescue StandardError
      invalid_data!
    end

    def coverage_date(value)
      date = if value.is_a?(Date) && !value.is_a?(DateTime)
        value
      elsif value.is_a?(String) && value.match?(FinecoItem::HistoryNormalizer::ISO_DATE_PATTERN)
        Date.iso8601(value)
      end
      invalid_data! unless date && date.iso8601 == value.to_s

      date
    rescue ArgumentError, Date::Error
      invalid_data!
    end

    def resolve_security!(provider_account, activity)
      provider_link = provider_account.account_provider
      history_holdings = provider_link.holdings.includes(:provider_security, :security).select do |holding|
        holding.provider_security&.ticker.to_s.casecmp?(activity.isin)
      end

      latest_date = history_holdings.map(&:date).max
      latest = history_holdings.select { |holding| holding.date == latest_date }
      security_ids = latest.map(&:security_id).uniq
      security_conflict! if security_ids.length > 1
      return latest.first.security if security_ids.one?

      existing = Security.find_by(ticker: activity.isin, exchange_operating_mic: nil)
      if existing
        security_conflict! unless existing.offline? && existing.price_provider.blank?
        return existing
      end

      Security.create!(
        ticker: activity.isin,
        exchange_operating_mic: nil,
        name: activity.name,
        offline: true,
        offline_reason: "fineco_isin"
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      existing = Security.find_by(ticker: activity.isin, exchange_operating_mic: nil)
      return existing if existing&.offline? && existing.price_provider.blank?

      security_conflict!
    end

    def trade_metadata(provider_account, activity)
      {
        "history_schema_version" => LEDGER_VERSION,
        "provider_account_id" => provider_account.id,
        "cash_account_external" => true,
        "fingerprint" => activity.fingerprint,
        "occurrence" => activity.occurrence,
        "original_price" => activity.metadata.fetch("original_price"),
        "original_currency" => activity.metadata.fetch("original_currency"),
        "exchange" => activity.metadata.fetch("exchange"),
        "value_date" => activity.metadata.fetch("value_date")
      }
    end

    def invalid_data!
      raise FinecoItem::PortfolioImportError.new(:history_invalid_data)
    end

    def history_changed!
      raise FinecoItem::PortfolioImportError.new(:history_changed)
    end

    def identity_changed!
      raise FinecoItem::PortfolioImportError.new(:history_identity_changed)
    end

    def security_conflict!
      raise FinecoItem::PortfolioImportError.new(:security_conflict)
    end
end
