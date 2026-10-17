# frozen_string_literal: true

class FinecoItem::HistorySyncer
  MINIMUM_DATE = Date.new(2018, 1, 1).freeze
  MAX_REQUESTS_PER_PASS = 100
  MAX_ROWS_PER_PASS = 10_000
  MAX_HISTORY_SECONDS = 120
  INITIAL_BALANCE_COVERAGE = Date.new(2018, 1, 1).freeze

  class Failure < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  class TimeoutFailure < StandardError; end

  def initialize(item)
    @item = item
  end

  def perform
    result = false

    @item.with_lock do
      begin
        validate_ready!
        account = @item.fineco_account
        linked_account_id = account.current_account.id
        coverage_start, coverage_end = coverage_for(account)
        Timeout.timeout(MAX_HISTORY_SECONDS, TimeoutFailure) do
          bank_scope = Digest::SHA256.hexdigest(
            JSON.generate([ @item.bank_account_number, @item.dossier_identity ])
          )
          first_pass, coverage_start = fetch_consistent_passes(
            coverage_start: coverage_start,
            coverage_end: coverage_end,
            bank_scope: bank_scope
          )

          import_under_owner_lock!(
            account: account,
            linked_account_id: linked_account_id,
            normalized: first_pass,
            coverage_start: coverage_start,
            coverage_end: coverage_end
          )
        end
        @item.update!(history_sync_error_code: nil) if @item.history_sync_error_code.present?
        result = true
      rescue Provider::Fineco::ReauthenticationRequired
        @item.require_reauthentication! unless @item.requires_update?
        @item.update!(history_sync_error_code: nil) if @item.history_sync_error_code.present?
        capture_failure("reauthentication_required", coverage_start, coverage_end)
      rescue Provider::Fineco::Error => error
        persist_rotated_session!(@current_client)
        record_failure!(provider_error_code(error), coverage_start, coverage_end)
      rescue FinecoItem::PortfolioImportError => error
        record_failure!(import_error_code(error), coverage_start, coverage_end)
      rescue Failure => error
        record_failure!(error.code, coverage_start, coverage_end)
      rescue TimeoutFailure
        record_failure!("history_incomplete", coverage_start, coverage_end)
      rescue StandardError => error
        record_failure!("history_sync_failed", coverage_start, coverage_end, error: error)
      ensure
        @current_client = nil
      end
    end

    result
  end

  private

    def validate_ready!
      unless ActiveRecordEncryptionConfig.explicitly_configured? &&
             Provider::Fineco.verified_identity_contract? && @item.ready_for_sync?
        raise Failure.new("history_sync_failed")
      end

      unless @item.fineco_account&.usable_account.present?
        raise Failure.new("history_sync_failed")
      end
    end

    def coverage_for(account)
      bank_today = Time.find_zone!(Provider::Fineco::BANK_TIME_ZONE).today
      coverage_end = bank_today - 1.day
      coverage_start = if complete_coverage?(account, coverage_end)
        contiguous_start = [ @completed_coverage_to + 1.day, bank_today.months_ago(3) ].min
        [ @completed_coverage_from, contiguous_start ].max
      else
        INITIAL_BALANCE_COVERAGE
      end

      raise Failure.new("history_incomplete") if coverage_start > coverage_end

      [ coverage_start, coverage_end ]
    end

    def complete_coverage?(account, coverage_end)
      @completed_coverage_from = nil
      @completed_coverage_to = nil
      return false unless account.history_synced_at.present?

      ledger = account.history_ledger
      return false unless ledger.is_a?(Hash)
      return false unless ledger["version"] == 1 || ledger[:version] == 1

      from_value = ledger["coverage_from"] || ledger[:coverage_from]
      to_value = ledger["coverage_to"] || ledger[:coverage_to]
      days = ledger["days"] || ledger[:days]
      from_date = parse_coverage_date(from_value)
      to_date = parse_coverage_date(to_value)

      valid = from_date.present? && to_date.present? && from_date >= MINIMUM_DATE &&
        from_date <= to_date && to_date <= coverage_end && days.is_a?(Hash)
      if valid
        @completed_coverage_from = from_date
        @completed_coverage_to = to_date
      end
      valid
    rescue StandardError
      false
    end

    def parse_coverage_date(value)
      return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.iso8601(value)
    rescue ArgumentError
      nil
    end

    def normalize_pass(rows, bank_scope)
      FinecoItem::HistoryNormalizer.new(rows: rows, bank_scope: bank_scope).normalize
    end

    def fetch_consistent_passes(coverage_start:, coverage_end:, bank_scope:)
      restarted = false

      loop do
        begin
          first_pass = normalize_pass(fetch_coverage(coverage_start, coverage_end, bank_scope), bank_scope)
          second_pass = normalize_pass(fetch_coverage(coverage_start, coverage_end, bank_scope), bank_scope)
          raise Failure.new("history_inconsistent") unless first_pass.cohorts == second_pass.cohorts

          return [ first_pass, coverage_start ]
        rescue Provider::Fineco::MovementsDateRangeUnavailable => error
          unless !restarted && coverage_start == INITIAL_BALANCE_COVERAGE &&
                 error.earliest_date > coverage_start && error.earliest_date <= coverage_end
            raise Failure.new("history_incomplete")
          end

          coverage_start = error.earliest_date
          restarted = true
        end
      end
    end

    def fetch_coverage(coverage_start, coverage_end, bank_scope)
      @request_count = 0
      @row_count = 0
      rows = []
      windows_for(coverage_start, coverage_end).each do |date_from, date_to|
        rows.concat(fetch_window(date_from, date_to, bank_scope))
      end
      rows
    end

    def windows_for(coverage_start, coverage_end)
      windows = []
      cursor = coverage_start

      while cursor <= coverage_end
        year_end = Date.new(cursor.year, 12, 31)
        window_end = [ year_end, coverage_end ].min
        windows << [ cursor, window_end ]
        cursor = window_end + 1.day
      end

      windows
    end

    def fetch_window(date_from, date_to, bank_scope)
      page = fetch_window_page(date_from, date_to)
      movements = validate_window_payload!(page.payload)
      normalized_window = normalize_pass(movements, bank_scope)
      unless normalized_window.activities.all? { |activity| activity.date.between?(date_from, date_to) }
        raise Failure.new("history_incomplete")
      end

      @row_count += movements.length
      raise Failure.new("history_incomplete") if @row_count > MAX_ROWS_PER_PASS

      movements
    rescue Provider::Fineco::MovementsWindowTooLarge
      raise Failure.new("history_incomplete") if date_from >= date_to

      midpoint = date_from + ((date_to - date_from) / 2)
      fetch_window(date_from, midpoint, bank_scope) + fetch_window(midpoint + 1.day, date_to, bank_scope)
    end

    def fetch_window_page(date_from, date_to)
      @request_count += 1
      raise Failure.new("history_incomplete") if @request_count > MAX_REQUESTS_PER_PASS

      client = Provider::Fineco.new(
        gsessionid: @item.gsessionid,
        account_index: @item.account_index,
        dossier_index: @item.dossier_index
      )
      @current_client = client

      begin
        page = client.fetch_movements_window(
          date_from: date_from,
          date_to: date_to,
          movement_type: "ORDER"
        )
      rescue Provider::Fineco::ReauthenticationRequired
        raise
      rescue Provider::Fineco::Error
        persist_rotated_session!(client)
        raise
      end

      verify_page_identity!(page, client)
      persist_rotated_session!(client)
      page
    end

    def validate_window_payload!(payload)
      unless payload.is_a?(Hash) && payload["movements"].is_a?(Array) &&
             [ true, false ].include?(payload["lastPage"]) &&
             [ true, false ].include?(payload["limitedResult"])
        raise Failure.new("history_incomplete")
      end
      raise Provider::Fineco::MovementsWindowTooLarge if payload["limitedResult"]
      raise Failure.new("history_incomplete") if payload["movements"].size >= Provider::Fineco::MAX_MOVEMENTS_PER_WINDOW

      payload.fetch("movements")
    end

    def verify_page_identity!(page, client)
      valid_result = page.respond_to?(:account_number) && page.respond_to?(:dossier_identity) &&
        @item.same_bank_identity?(account_number: page.account_number, dossier_identity: page.dossier_identity)
      verified_identity = client.last_verified_bank_identity
      valid_client = verified_identity&.matches?(
        account_number: @item.bank_account_number,
        dossier_identity: @item.dossier_identity
      )
      raise Failure.new("history_identity_changed") unless valid_result && valid_client
    end

    def persist_rotated_session!(client)
      rotated_gsessionid = client&.last_rotated_gsessionid
      identity = client&.last_verified_bank_identity
      return unless rotated_gsessionid.present? && identity&.matches?(
        account_number: @item.bank_account_number,
        dossier_identity: @item.dossier_identity
      )

      @item.update!(gsessionid: rotated_gsessionid)
    end

    def import_under_owner_lock!(account:, linked_account_id:, normalized:, coverage_start:, coverage_end:)
      owner = User.find_by(id: @item.owner_id, family_id: @item.family_id)
      raise Failure.new("history_sync_failed") unless owner

      owner.with_lock do
        current_account = @item.fineco_account
        unless owner.active? && @item.ready_for_sync? && current_account&.id == account.id &&
               current_account.current_account&.id == linked_account_id
          raise Failure.new("history_identity_changed")
        end

        FinecoItem::HistoryImporter.new(@item).import(
          normalized: normalized,
          coverage_start: coverage_start,
          coverage_end: coverage_end
        )
      end
    end

    def provider_error_code(error)
      case error
      when Provider::Fineco::InvalidResponse, Provider::Fineco::ResponseTooLarge,
           Provider::Fineco::RequestTimeout
        "history_incomplete"
      else
        "history_sync_failed"
      end
    end

    def import_error_code(error)
      case error.code.to_s
      when "history_invalid_data", "history_unsupported_activity"
        error.code.to_s
      when "history_changed", "history_identity_changed"
        error.code.to_s
      else
        "history_sync_failed"
      end
    end

    def record_failure!(code, coverage_start, coverage_end, error: nil)
      allowed_codes = %w[
        history_sync_failed history_incomplete history_inconsistent history_identity_changed
        history_changed history_invalid_data history_unsupported_activity
      ]
      safe_code = allowed_codes.include?(code) ? code : "history_sync_failed"
      persist_rotated_session!(@current_client) unless safe_code == "history_identity_changed"
      if safe_code == "history_identity_changed" && !@item.requires_update?
        @item.require_reauthentication!(code: "account_identity_changed")
      end
      @item.update!(history_sync_error_code: safe_code)
      capture_failure(safe_code, coverage_start, coverage_end, error: error)
    end

    def capture_failure(code, coverage_start, coverage_end, error: nil)
      account = @item.fineco_account
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Fineco activity history could not be synchronized.",
        source: "fineco",
        provider_key: "fineco",
        family: @item.family,
        user: @item.owner,
        account_provider: account&.account_provider,
        metadata: {
          fineco_item_id: @item.id,
          history_sync_error_code: code,
          coverage_from: coverage_start&.iso8601,
          coverage_to: coverage_end&.iso8601,
          error_class: error&.class&.name
        }.compact
      )
    end
end
