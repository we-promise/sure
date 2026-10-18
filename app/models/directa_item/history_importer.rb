# frozen_string_literal: true

class DirectaItem::HistoryImporter
  SOURCE = "directa".freeze
  LEDGER_VERSION = 1
  FINGERPRINT_PATTERN = /\A[0-9a-f]{64}\z/.freeze
  EXTERNAL_ID_PATTERN = /\Adirecta-history-v1:[0-9a-f]{64}\z/.freeze
  MINIMUM_DATE = Date.new(2018, 1, 1)
  MAX_ROWS = 5_000
  MAX_TEXT_BYTES = 2_048

  Scope = Data.define(
    :account_number,
    :account_identity,
    :connection_generation,
    :owner_id,
    :family_id,
    :provider_account_id,
    :linked_account_id,
    :account_provider_id
  ) do
    def initialize(account_number:, account_identity:, connection_generation:, owner_id:, family_id:,
      provider_account_id:, linked_account_id:, account_provider_id:)
      super(
        account_number: account_number.to_s.dup.freeze,
        account_identity: account_identity.to_s.dup.freeze,
        connection_generation: Integer(connection_generation),
        owner_id: owner_id.to_s.dup.freeze,
        family_id: family_id.to_s.dup.freeze,
        provider_account_id: provider_account_id.to_s.dup.freeze,
        linked_account_id: linked_account_id.to_s.dup.freeze,
        account_provider_id: account_provider_id.to_s.dup.freeze
      )
    end

    def inspect
      "#<#{self.class.name}: verified generation=#{connection_generation}>"
    end
    alias to_s inspect
  end

  def initialize(item)
    @item = item
  end

  def import(normalized:, coverage_start:, coverage_end:, scope:)
    from_date = coverage_date(coverage_start)
    to_date = coverage_date(coverage_end)
    bank_yesterday = Time.current.in_time_zone("Europe/Rome").to_date - 1.day
    invalid_data! if from_date < MINIMUM_DATE || from_date.day != 1 || from_date > to_date || to_date > bank_yesterday
    validate_normalized!(normalized, from_date, to_date)
    invalid_data! unless scope.is_a?(Scope)
    bank_scope = Digest::SHA256.hexdigest(JSON.generate([ scope.account_number, scope.account_identity ]))

    imported_count = 0
    linked_account = nil

    ApplicationRecord.transaction(requires_new: true) do
      @item.with_lock do
        provider_account, owner, linked_account = validate_scope!(scope, bank_scope)

        owner.with_lock do
          provider_account.reload
          provider_account, owner, current_account = validate_scope!(scope, bank_scope, lock_linked_rows: true)
          linked_account = current_account

          prior_ledger = normalized_ledger(provider_account, bank_scope)
          ledger, new_activities = advance_ledger(
            prior_ledger: prior_ledger,
            normalized: normalized,
            coverage_start: from_date,
            coverage_end: to_date,
            bank_scope: bank_scope
          )

          provider_account.update!(history_ledger: ledger, history_synced_at: Time.current)
          imported_count = import_activities!(
            provider_account: provider_account,
            account: linked_account,
            activities: new_activities,
            bank_scope: bank_scope
          )

          begin
            DirectaAccount::ContentValidator.new(provider_account).validate!
          rescue DirectaItem::PortfolioNormalizer::Error => error
            raise unless error.code == "holding_conflict"

            history_changed!
          end
          @item.clear_history_sync_failure!
        end
      end
    end

    ActiveRecord.after_all_transactions_commit { linked_account.sync_later } if imported_count.positive?
    imported_count
  rescue DirectaItem::PortfolioNormalizer::Error
    raise
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
    history_changed!
  end

  def inspect
    "#<#{self.class.name}: redacted>"
  end
  alias to_s inspect

  private

    def validate_scope!(scope, bank_scope, lock_linked_rows: false)
      identity_changed! unless @item.persisted? && @item.owner_id.present? && @item.family_id.present?
      identity_changed! unless ActiveRecordEncryptionConfig.explicitly_configured? && @item.ready_for_sync?
      identity_changed! unless @item.connection_generation == scope.connection_generation
      identity_changed! unless @item.owner_id.to_s == scope.owner_id && @item.family_id.to_s == scope.family_id
      identity_changed! unless secure_equal?(@item.broker_account, scope.account_number)
      identity_changed! unless secure_equal?(@item.account_identity, scope.account_identity)
      identity_changed! unless secure_equal?(current_bank_scope, bank_scope)

      provider_account = @item.directa_accounts.find_by(id: scope.provider_account_id)
      identity_changed! unless provider_account
      provider_link = provider_account.account_provider
      if lock_linked_rows
        provider_link&.lock!
        provider_link&.reload
      end
      identity_changed! unless provider_link&.id.to_s == scope.account_provider_id &&
        provider_link.provider_type == "DirectaAccount" && provider_link.provider_id == provider_account.id

      linked_account = provider_link.account
      if lock_linked_rows
        linked_account&.lock!
        linked_account&.reload
      end
      provider_account.association(:account_provider).reset
      linked_account = provider_account.usable_account
      identity_changed! unless linked_account&.id.to_s == scope.linked_account_id

      owner = User.find_by(id: scope.owner_id, family_id: scope.family_id)
      identity_changed! unless owner&.active?
      [ provider_account, owner, linked_account ]
    end

    def current_bank_scope
      Digest::SHA256.hexdigest(JSON.generate([ @item.broker_account, @item.account_identity ]))
    end

    def normalized_ledger(provider_account, bank_scope)
      raw = provider_account.history_ledger
      synced_at = provider_account.history_synced_at
      return empty_ledger(bank_scope) if raw.nil? && synced_at.nil?
      history_changed! unless raw.is_a?(Hash) && synced_at.present?
      history_changed! unless raw.keys.sort == %w[bank_scope cohorts coverage_end coverage_start entries schema_version]
      history_changed! unless raw["schema_version"].instance_of?(Integer) && raw["schema_version"] == LEDGER_VERSION
      history_changed! unless raw["bank_scope"].is_a?(String) && secure_equal?(raw["bank_scope"], bank_scope)

      from_date = coverage_date(raw["coverage_start"])
      to_date = coverage_date(raw["coverage_end"])
      bank_yesterday = Time.current.in_time_zone("Europe/Rome").to_date - 1.day
      history_changed! unless from_date >= MINIMUM_DATE && from_date.day == 1 &&
        from_date <= to_date && to_date <= bank_yesterday
      history_changed! unless raw["entries"].is_a?(Hash) && raw["entries"].length <= MAX_ROWS
      history_changed! unless raw["cohorts"].is_a?(Hash)

      cohorts = normalize_cohorts(raw["cohorts"], from_date, to_date)
      entries = normalize_entries(raw["entries"], from_date, to_date)
      history_changed! unless cohorts == cohorts_from_entries(entries, from_date, to_date)

      {
        "schema_version" => LEDGER_VERSION,
        "bank_scope" => bank_scope,
        "coverage_start" => from_date.iso8601,
        "coverage_end" => to_date.iso8601,
        "cohorts" => cohorts,
        "entries" => entries
      }
    rescue DirectaItem::PortfolioNormalizer::Error
      raise
    rescue ArgumentError, TypeError, Date::Error
      history_changed!
    end

    def empty_ledger(bank_scope)
      {
        "schema_version" => LEDGER_VERSION,
        "bank_scope" => bank_scope,
        "coverage_start" => nil,
        "coverage_end" => nil,
        "cohorts" => {},
        "entries" => {}
      }
    end

    def normalize_cohorts(cohorts, from_date, to_date)
      expected_days = (from_date..to_date).map(&:iso8601)
      history_changed! unless cohorts.keys.sort == expected_days.sort

      cohorts.each_with_object({}) do |(day, counts), result|
        parsed_day = coverage_date(day)
        history_changed! unless parsed_day.iso8601 == day && counts.is_a?(Hash)
        history_changed! unless counts.all? do |fingerprint, count|
          fingerprint.is_a?(String) && fingerprint.match?(FINGERPRINT_PATTERN) &&
            count.instance_of?(Integer) && count.positive?
        end
        result[day] = counts.sort.to_h
      end
    end

    def normalize_entries(entries, from_date, to_date)
      entries.each_with_object({}) do |(external_id, value), result|
        history_changed! unless external_id.is_a?(String) && external_id.match?(EXTERNAL_ID_PATTERN)
        history_changed! unless value.is_a?(Hash) && value.keys.sort == %w[date fingerprint]

        date = coverage_date(value["date"])
        fingerprint = value["fingerprint"]
        history_changed! unless date.between?(from_date, to_date) &&
          fingerprint.is_a?(String) && fingerprint.match?(FINGERPRINT_PATTERN)
        result[external_id] = { "fingerprint" => fingerprint, "date" => date.iso8601 }
      end
    end

    def cohorts_from_entries(entries, from_date, to_date)
      cohorts = (from_date..to_date).to_h { |date| [ date.iso8601, Hash.new(0) ] }
      entries.each_value do |entry|
        cohorts.fetch(entry.fetch("date"))[entry.fetch("fingerprint")] += 1
      end
      cohorts.transform_values { |counts| counts.sort.to_h }
    end

    def advance_ledger(prior_ledger:, normalized:, coverage_start:, coverage_end:, bank_scope:)
      prior_from = prior_ledger["coverage_start"] && coverage_date(prior_ledger["coverage_start"])
      prior_to = prior_ledger["coverage_end"] && coverage_date(prior_ledger["coverage_end"])
      history_changed! if prior_from && coverage_start > prior_to + 1.day

      incoming_cohorts = normalize_incoming_cohorts(
        normalized.cohorts, normalized.activities, coverage_start, coverage_end
      )
      prior_entries = prior_ledger.fetch("entries")
      incoming_entries = activity_entries(normalized.activities, coverage_start, coverage_end)
      reject_changed_covered_history!(
        prior_ledger: prior_ledger,
        incoming_cohorts: incoming_cohorts,
        incoming_entries: incoming_entries,
        coverage_start: coverage_start,
        coverage_end: coverage_end
      )

      entries = prior_entries.deep_dup
      new_activities = []
      normalized.activities.each do |activity|
        entry = incoming_entries.fetch(activity.external_id)
        prior_entry = entries[activity.external_id]
        if prior_entry
          history_changed! unless prior_entry == entry
        else
          history_changed! if entries.length >= MAX_ROWS
          entries[activity.external_id] = entry
          new_activities << activity
        end
      end

      cohorts = prior_ledger.fetch("cohorts").deep_dup
      incoming_cohorts.each { |day, counts| cohorts[day] = counts }
      new_from = prior_from ? [ prior_from, coverage_start ].min : coverage_start
      new_to = prior_to ? [ prior_to, coverage_end ].max : coverage_end
      full_cohorts = (new_from..new_to).to_h do |date|
        day = date.iso8601
        counts = cohorts[day]
        history_changed! unless counts.is_a?(Hash)
        [ day, counts ]
      end

      [
        {
          "schema_version" => LEDGER_VERSION,
          "bank_scope" => bank_scope,
          "coverage_start" => new_from.iso8601,
          "coverage_end" => new_to.iso8601,
          "cohorts" => full_cohorts,
          "entries" => entries.sort.to_h
        },
        new_activities
      ]
    end

    def normalize_incoming_cohorts(cohorts, activities, from_date, to_date)
      invalid_data! unless cohorts.is_a?(Hash)
      expected = Hash.new { |days, day| days[day] = Hash.new(0) }
      activities.each { |activity| expected[activity.date.iso8601][activity.fingerprint] += 1 }
      expected = expected.transform_values { |counts| counts.sort.to_h }
      invalid_data! unless cohorts == expected

      (from_date..to_date).to_h { |date| [ date.iso8601, expected.fetch(date.iso8601, {}) ] }
    end

    def activity_entries(activities, from_date, to_date)
      invalid_data! if activities.length > MAX_ROWS
      activities.each_with_object({}) do |activity, result|
        invalid_data! unless activity.date.between?(from_date, to_date)
        invalid_data! if result.key?(activity.external_id)
        result[activity.external_id] = {
          "fingerprint" => activity.fingerprint,
          "date" => activity.date.iso8601
        }
      end
    end

    def reject_changed_covered_history!(prior_ledger:, incoming_cohorts:, incoming_entries:, coverage_start:, coverage_end:)
      prior_from = prior_ledger["coverage_start"] && coverage_date(prior_ledger["coverage_start"])
      prior_to = prior_ledger["coverage_end"] && coverage_date(prior_ledger["coverage_end"])
      return unless prior_from && prior_to

      overlap_from = [ prior_from, coverage_start ].max
      overlap_to = [ prior_to, coverage_end ].min
      return if overlap_from > overlap_to

      (overlap_from..overlap_to).each do |date|
        day = date.iso8601
        old_counts = prior_ledger.fetch("cohorts").fetch(day)
        new_counts = incoming_cohorts.fetch(day)
        history_changed! if old_counts.any? { |fingerprint, count| new_counts.fetch(fingerprint, 0) < count }
      end

      prior_ledger.fetch("entries").each do |external_id, old_entry|
        date = coverage_date(old_entry.fetch("date"))
        next unless date.between?(overlap_from, overlap_to)

        history_changed! unless incoming_entries[external_id] == old_entry
      end
    end

    def import_activities!(provider_account:, account:, activities:, bank_scope:)
      adapter = Account::ProviderImportAdapter.new(account)
      imported = 0

      activities.each do |activity|
        matches = account.entries.includes(:entryable).where(external_id: activity.external_id).to_a
        if matches.any?
          history_changed! unless matches.one? && matches.sole.source == SOURCE && matches.sole.entryable.is_a?(Trade)
          next
        end

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
          source: SOURCE,
          fee: activity.fee
        )
        entry.entryable.update!(extra: (entry.entryable.extra || {}).merge(
          "directa" => trade_metadata(provider_account, activity, bank_scope)
        ))
        imported += 1
      end

      imported
    end

    def trade_metadata(provider_account, activity, bank_scope)
      {
        "history_schema_version" => LEDGER_VERSION,
        "provider_account_id" => provider_account.id.to_s,
        "fingerprint" => activity.fingerprint,
        "bank_scope" => bank_scope,
        "aggregation" => Trade::DIRECTA_HISTORY_AGGREGATION,
        "isin" => activity.isin,
        "quantity" => activity.quantity.to_s("F"),
        "price_eur" => activity.price.to_s("F"),
        "amount_eur" => activity.amount.to_s("F"),
        "fee_eur" => activity.fee.to_s("F")
      }.merge(safe_activity_metadata(activity.metadata))
    end

    def safe_activity_metadata(metadata)
      return {} unless metadata.is_a?(Hash)

      allowed_keys = %w[
        quote_currency original_prices fill_count commission_reported
        commission_reported_fill_count fee_scope gross_eur value_dates
      ]
      metadata.slice(*allowed_keys).each_with_object({}) do |(key, value), result|
        result[key] = value if safe_metadata_value?(value)
      end
    end

    def safe_metadata_value?(value)
      case value
      when String
        value.bytesize <= MAX_TEXT_BYTES && value.valid_encoding? && !value.match?(/[\u0000-\u001F\u007F]/)
      when Integer, TrueClass, FalseClass, NilClass
        true
      when Array
        value.length <= 100 && value.all? { |item| item.is_a?(String) && safe_metadata_value?(item) }
      else
        false
      end
    end

    def resolve_security!(provider_account, activity)
      isin = activity.isin.upcase
      provider_link = provider_account.account_provider
      holdings = provider_link.holdings.includes(:provider_security, :security).select do |holding|
        holding.provider_security&.ticker.to_s.casecmp?(isin) ||
          holding.security&.ticker.to_s.casecmp?(isin)
      end
      latest_date = holdings.map(&:date).max
      latest = holdings.select { |holding| holding.date == latest_date }
      security_ids = latest.map(&:security_id).uniq
      unsupported_activity! if security_ids.length > 1
      return latest.first.security if security_ids.one?

      existing = Security.find_by(ticker: isin, exchange_operating_mic: nil)
      if existing
        unsupported_activity! unless existing.offline? && existing.price_provider.blank?
        return existing
      end

      Security.create!(
        ticker: isin,
        exchange_operating_mic: nil,
        name: activity.name,
        offline: true,
        offline_reason: "directa_isin"
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      existing = Security.find_by(ticker: isin, exchange_operating_mic: nil)
      return existing if existing&.offline? && existing.price_provider.blank?

      unsupported_activity!
    end

    def validate_normalized!(normalized, from_date, to_date)
      invalid_data! unless normalized.is_a?(DirectaItem::HistoryNormalizer::Result)
      activities = normalized.activities
      cohorts = normalized.cohorts
      invalid_data! unless activities.is_a?(Array) && cohorts.is_a?(Hash) && activities.length <= MAX_ROWS

      expected = Hash.new { |days, day| days[day] = Hash.new(0) }
      external_ids = {}
      occurrences = Hash.new { |groups, key| groups[key] = [] }
      activities.each do |activity|
        fields = %i[date isin name quantity price amount fee currency external_id fingerprint occurrence metadata]
        invalid_data! unless fields.all? { |field| activity.respond_to?(field) }
        invalid_data! unless activity.date.instance_of?(Date) && activity.date.between?(from_date, to_date)
        invalid_data! unless valid_fingerprint?(activity.fingerprint)
        invalid_data! unless activity.external_id.is_a?(String) && activity.external_id.match?(EXTERNAL_ID_PATTERN)
        invalid_data! if external_ids[activity.external_id]
        invalid_data! unless activity.isin.is_a?(String) && DirectaItem::PortfolioNormalizer.valid_isin?(activity.isin)
        invalid_data! unless activity.name.is_a?(String) && activity.name.bytesize.between?(1, MAX_TEXT_BYTES) &&
          activity.name.valid_encoding? && !activity.name.match?(/[\u0000-\u001F\u007F]/)
        invalid_data! unless activity.quantity.is_a?(BigDecimal) && activity.quantity.finite? && !activity.quantity.zero?
        invalid_data! unless activity.price.is_a?(BigDecimal) && activity.price.finite? && activity.price.positive?
        invalid_data! unless activity.amount.is_a?(BigDecimal) && activity.amount.finite?
        invalid_data! unless activity.fee.is_a?(BigDecimal) && activity.fee.finite? && activity.fee >= 0
        invalid_data! unless activity.currency == "EUR" && activity.metadata.is_a?(Hash)
        invalid_data! unless activity.occurrence.instance_of?(Integer) && activity.occurrence.positive?

        external_ids[activity.external_id] = true
        expected[activity.date.iso8601][activity.fingerprint] += 1
        occurrences[[ activity.date.iso8601, activity.fingerprint ]] << activity.occurrence
      end
      occurrences.each_value { |values| invalid_data! unless values.sort == (1..values.length).to_a }
      invalid_data! unless expected.transform_values { |counts| counts.sort.to_h } == cohorts
    rescue DirectaItem::PortfolioNormalizer::Error
      raise
    rescue StandardError
      invalid_data!
    end

    def coverage_date(value)
      date = if value.is_a?(Date) && !value.is_a?(DateTime)
        value
      elsif value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.iso8601(value)
      end
      invalid_data! unless date && date.iso8601 == value.to_s

      date
    rescue ArgumentError, Date::Error
      invalid_data!
    end

    def secure_equal?(left, right)
      return false if left.blank? || right.blank?
      return false unless left.to_s.bytesize == right.to_s.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
    end

    def valid_fingerprint?(value)
      value.is_a?(String) && value.match?(FINGERPRINT_PATTERN)
    end

    def invalid_data!
      raise DirectaItem::PortfolioNormalizer::Error.new(:history_invalid_data)
    end

    def history_changed!
      raise DirectaItem::PortfolioNormalizer::Error.new(:history_changed)
    end

    def identity_changed!
      raise DirectaItem::PortfolioNormalizer::Error.new(:history_identity_changed)
    end

    def unsupported_activity!
      raise DirectaItem::PortfolioNormalizer::Error.new(:history_unsupported_activity)
    end
end
