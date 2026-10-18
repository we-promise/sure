# frozen_string_literal: true

require "digest"
require "json"
require "timeout"

class DirectaItem::HistorySyncer
  MINIMUM_DATE = Date.new(2018, 1, 1).freeze
  MAX_SOURCE_REQUESTS = 120
  MAX_ROWS_PER_PASS = 10_000
  MAX_HISTORY_SECONDS = 180
  MAX_STATEMENT_MONTHS = 120

  class Failure < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  class TimeoutFailure < StandardError; end

  class SourceRequestBudget
    SOURCE_OPERATIONS = %i[executed_orders account_statement].freeze

    def initialize(limit: MAX_SOURCE_REQUESTS)
      @limit = limit
      @used = 0
      @delegate = Provider::Directa::HttpTransport.new
    end

    def request(operation, **options)
      if SOURCE_OPERATIONS.include?(operation)
        @used += 1
        raise Failure.new("history_incomplete") if @used > @limit
      end

      @delegate.request(operation, **options)
    end
  end

  def initialize(item)
    @item = item
  end

  def perform
    @captured_generation = @item.connection_generation
    @source_request_budget = SourceRequestBudget.new
    Timeout.timeout(MAX_HISTORY_SECONDS, TimeoutFailure) do
      captured_scope = capture_scope
      coverage_start, coverage_end = coverage_for(captured_scope.fetch(:provider_account))
      bank_scope = Digest::SHA256.hexdigest(
        JSON.generate([ captured_scope.fetch(:session).account_number, captured_scope.fetch(:session).account_identity ])
      )

      first = fetch_pass(
        session: captured_scope.fetch(:session),
        coverage_start: coverage_start,
        coverage_end: coverage_end,
        bank_scope: bank_scope
      )
      second = fetch_pass(
        session: captured_scope.fetch(:session),
        coverage_start: coverage_start,
        coverage_end: coverage_end,
        bank_scope: bank_scope
      )
      raise Failure.new("history_changed") unless consistent?(first, second)

      validate_captured_scope!(captured_scope)
      importer_scope = importer_scope(captured_scope)
      DirectaItem::HistoryImporter.new(@item).import(
        normalized: first,
        coverage_start: coverage_start,
        coverage_end: coverage_end,
        scope: importer_scope
      )
    end
    true
  rescue TimeoutFailure, Timeout::Error
    record_failure("history_incomplete")
    false
  rescue Provider::Directa::AuthenticationError
    record_failure("history_sync_failed", require_update: true)
    false
  rescue Provider::Directa::AccountIdentityMismatch
    record_failure("history_identity_changed")
    false
  rescue DirectaItem::PortfolioNormalizer::Error => error
    record_failure(history_error_code(error.code))
    false
  rescue Provider::Directa::Error => error
    record_failure(provider_error_code(error))
    false
  rescue Failure => error
    record_failure(error.code)
    false
  rescue StandardError
    record_failure("history_sync_failed")
    false
  ensure
    @captured_generation = nil
    @source_request_budget = nil
  end

  def inspect
    "#<#{self.class.name}: redacted>"
  end
  alias to_s inspect

  private

    def capture_scope
      validate_ready!
      session = @item.verified_session
      provider_account = @item.directa_account
      linked_account = provider_account&.usable_account
      provider_link = provider_account&.account_provider
      raise Failure.new("history_sync_failed") unless session && provider_account && linked_account && provider_link
      raise Failure.new("history_identity_changed") unless session.connection_generation == @captured_generation
      raise Failure.new("history_identity_changed") unless secure_equal?(session.account_number, @item.broker_account)
      raise Failure.new("history_identity_changed") unless secure_equal?(session.account_identity, @item.account_identity)
      raise Failure.new("history_identity_changed") unless provider_link.provider_type == "DirectaAccount" &&
        provider_link.provider_id == provider_account.id && provider_link.account_id == linked_account.id

      {
        session: session,
        provider_account: provider_account,
        provider_account_id: provider_account.id,
        linked_account_id: linked_account.id,
        account_provider_id: provider_link.id,
        owner_id: @item.owner_id,
        family_id: @item.family_id
      }
    end

    def validate_ready!
      return if @item.persisted? && ActiveRecordEncryptionConfig.explicitly_configured? && @item.ready_for_sync?

      raise Failure.new("history_sync_failed")
    end

    def coverage_for(provider_account)
      bank_today = Time.find_zone!(Provider::Directa::History::BANK_TIME_ZONE).today
      coverage_end = bank_today - 1.day
      ledger = provider_account.history_ledger
      synced_at = provider_account.history_synced_at

      if ledger.nil? && synced_at.nil?
        coverage_start = MINIMUM_DATE
      else
        from_date, to_date = validated_coverage(ledger, synced_at, coverage_end)
        overlap_start = [ bank_today.months_ago(3).beginning_of_month, from_date ].max
        gap_start = (to_date + 1.day).beginning_of_month
        coverage_start = [ overlap_start, gap_start ].min
      end

      raise Failure.new("history_incomplete") if coverage_start > coverage_end

      [ coverage_start, coverage_end ]
    end

    def validated_coverage(ledger, synced_at, coverage_end)
      raise Failure.new("history_changed") unless ledger.is_a?(Hash) && synced_at.present?
      raise Failure.new("history_changed") unless ledger.keys.sort == %w[bank_scope cohorts coverage_end coverage_start entries schema_version]
      raise Failure.new("history_changed") unless ledger["schema_version"].instance_of?(Integer) &&
        ledger["schema_version"] == DirectaItem::HistoryImporter::LEDGER_VERSION

      expected_scope = Digest::SHA256.hexdigest(JSON.generate([ @item.broker_account, @item.account_identity ]))
      raise Failure.new("history_identity_changed") unless secure_equal?(ledger["bank_scope"], expected_scope)

      from_date = strict_date(ledger["coverage_start"])
      to_date = strict_date(ledger["coverage_end"])
      raise Failure.new("history_changed") unless from_date && to_date && from_date >= MINIMUM_DATE &&
        from_date.day == 1 && from_date <= to_date && to_date <= coverage_end
      raise Failure.new("history_changed") unless ledger["entries"].is_a?(Hash) &&
        ledger["entries"].length <= MAX_ROWS_PER_PASS && ledger["cohorts"].is_a?(Hash)

      expected_dates = (from_date..to_date).map(&:iso8601)
      raise Failure.new("history_changed") unless ledger["cohorts"].keys.sort == expected_dates.sort

      [ from_date, to_date ]
    end

    def fetch_pass(session:, coverage_start:, coverage_end:, bank_scope:)
      reader = Provider::Directa::History.new(session: session, http_transport: @source_request_budget)
      orders_result = reader.fetch_orders(date_from: coverage_start, date_to: coverage_end)
      validate_orders_result!(orders_result, session, coverage_start, coverage_end)
      orders = orders_result.orders
      raise Failure.new("history_incomplete") if orders.length > MAX_ROWS_PER_PASS

      statement_dates = statement_dates_for(orders, coverage_end)
      statement_bytes = 0
      statements = statement_dates.each_with_object({}) do |date, result|
        statement_result = reader.fetch_statement(date: date)
        validate_statement_result!(statement_result, session, date)
        statement_bytes += statement_result.body.bytesize
        raise Failure.new("history_incomplete") if statement_bytes > DirectaItem::HistoryNormalizer::MAX_TOTAL_STATEMENT_BYTES
        result[date] = statement_result.body
      end

      normalized = DirectaItem::HistoryNormalizer.new(
        orders: orders,
        statements: statements,
        bank_scope: bank_scope,
        coverage_start: coverage_start,
        coverage_end: coverage_end
      ).normalize
      raise Failure.new("history_incomplete") if normalized.activities.length > MAX_ROWS_PER_PASS

      normalized
    end

    def validate_orders_result!(result, session, coverage_start, coverage_end)
      unless result.is_a?(Provider::Directa::History::OrdersResult) && result.complete == true &&
          result.date_from == coverage_start && result.date_to == coverage_end
        raise Failure.new("history_incomplete")
      end
      validate_result_scope!(result.scope, session)
    end

    def validate_statement_result!(result, session, requested_date)
      unless result.is_a?(Provider::Directa::History::StatementResult) && result.date == requested_date &&
          result.body.is_a?(String) && result.body.bytesize <= Provider::Directa::History::STATEMENT_BODY_LIMIT_BYTES
        raise Failure.new("history_incomplete")
      end
      validate_result_scope!(result.scope, session)
    end

    def validate_result_scope!(scope, session)
      unless scope.is_a?(Provider::Directa::History::SessionScope) &&
          scope.connection_generation == @captured_generation &&
          secure_equal?(scope.account_number, session.account_number) &&
          secure_equal?(scope.account_identity, session.account_identity)
        raise Failure.new("history_identity_changed")
      end
    end

    def statement_dates_for(orders, coverage_end)
      raise Failure.new("history_incomplete") unless orders.is_a?(Array)

      dates = {}
      orders.each do |row|
        raise Failure.new("history_invalid_data") unless row.is_a?(Hash)
        placement = order_date(row["DataImmissione"])
        event = order_date(row["DataEvento"])
        raise Failure.new("history_invalid_data") unless placement >= MINIMUM_DATE && placement <= event

        month = Date.new(placement.year, placement.month, 1)
        last_month = Date.new(event.year, event.month, 1)
        while month <= last_month
          month_end = Date.new(month.year, month.month, -1)
          dates[[ month_end, coverage_end ].min] = true
          raise Failure.new("history_incomplete") if dates.length > MAX_STATEMENT_MONTHS
          month = month >> 1
        end
      end
      dates.keys.sort
    end

    def order_date(value)
      raw = value.to_s
      raise Failure.new("history_invalid_data") unless (value.is_a?(Integer) || value.is_a?(String)) &&
        raw.match?(/\A[0-9]{8}\z/)

      Date.strptime(raw, "%Y%m%d")
    rescue Date::Error
      raise Failure.new("history_invalid_data")
    end

    def consistent?(left, right)
      activity_signature(left) == activity_signature(right) && canonical_cohorts(left.cohorts) == canonical_cohorts(right.cohorts)
    end

    def activity_signature(normalized)
      normalized.activities.map do |activity|
        [ activity.external_id, activity.fingerprint ]
      end.sort
    end

    def canonical_cohorts(cohorts)
      return nil unless cohorts.is_a?(Hash)

      cohorts.sort.to_h do |date, values|
        [ date, values.is_a?(Hash) ? values.sort.to_h : values ]
      end
    end

    def validate_captured_scope!(captured)
      @item.reload
      session = captured.fetch(:session)
      raise Failure.new("history_identity_changed") unless @item.connection_generation == @captured_generation &&
        @item.owner_id.to_s == captured.fetch(:owner_id).to_s &&
        @item.family_id.to_s == captured.fetch(:family_id).to_s &&
        secure_equal?(@item.broker_account, session.account_number) &&
        secure_equal?(@item.account_identity, session.account_identity)
      validate_ready!
      provider_account = @item.directa_accounts.find_by(id: captured.fetch(:provider_account_id))
      linked_account = provider_account&.usable_account
      provider_link = provider_account&.account_provider
      same_account = provider_account && linked_account&.id == captured.fetch(:linked_account_id) &&
        provider_link&.id == captured.fetch(:account_provider_id) &&
        provider_link.provider_type == "DirectaAccount" && provider_link.provider_id == provider_account.id
      raise Failure.new("history_identity_changed") unless same_account
    end

    def importer_scope(captured)
      DirectaItem::HistoryImporter::Scope.new(
        account_number: captured.fetch(:session).account_number,
        account_identity: captured.fetch(:session).account_identity,
        connection_generation: captured.fetch(:session).connection_generation,
        owner_id: captured.fetch(:owner_id),
        family_id: captured.fetch(:family_id),
        provider_account_id: captured.fetch(:provider_account_id),
        linked_account_id: captured.fetch(:linked_account_id),
        account_provider_id: captured.fetch(:account_provider_id)
      )
    end

    def history_error_code(code)
      DirectaItem::HISTORY_SYNC_ERROR_CODES.include?(code.to_s) ? code.to_s : "history_sync_failed"
    end

    def provider_error_code(error)
      code = error.failure_code.to_s
      return "history_identity_changed" if code.include?("identity")
      return "history_invalid_data" if code.match?(/invalid|duplicate|sequence/)

      "history_incomplete"
    end

    def record_failure(code, require_update: false)
      return unless @item.persisted? && @captured_generation && ActiveRecordEncryptionConfig.explicitly_configured?

      @item.with_lock do
        next unless @item.connection_generation == @captured_generation

        @item.update!(status: :requires_update) if require_update && @item.connected?
        @item.record_history_sync_failure!(history_error_code(code))
      end
      capture_failure(history_error_code(code))
    rescue StandardError
      nil
    end

    def capture_failure(code)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Directa activity history sync failed with #{code}.",
        source: "directa",
        family: @item.family,
        account_provider: @item.directa_account&.account_provider,
        provider_key: "directa",
        metadata: { item_id: @item.id, error_code: code }
      )
    rescue StandardError
      nil
    end

    def strict_date(value)
      return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      date = Date.iso8601(value)
      date if date.iso8601 == value
    rescue Date::Error
      nil
    end

    def secure_equal?(left, right)
      return false unless left.is_a?(String) && right.is_a?(String) && left.present? && right.present?
      return false unless left.bytesize == right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
end
