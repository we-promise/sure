class TruelayerAccount::Processor
  include CurrencyNormalizable

  attr_reader :truelayer_account

  def initialize(truelayer_account)
    @truelayer_account = truelayer_account
  end

  # Returns { imported:, failed:, errors: } for the account's transactions,
  # or nil when the TrueLayer account isn't linked to a Sure account.
  def process
    account = truelayer_account.current_account
    unless account.present?
      Rails.logger.info "TruelayerAccount::Processor - No linked account for truelayer_account #{truelayer_account.id}, skipping"
      return
    end

    process_balance!(account)
    process_transactions
  rescue StandardError => e
    report_exception(e)
    raise
  end

  private

    def process_balance!(account)
      balance = truelayer_account.current_balance
      # nil means no balance fetch has succeeded yet. Leave the account as is
      # rather than writing a zero balance over a healthy one.
      return if balance.nil?

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: parse_currency(truelayer_account.currency) || account.currency
      )
    end

    # One bad row must not stop the rest, but it must not vanish either: the
    # failures are returned for sync health and captured for support. Rows
    # before the connection's start date are left out.
    def process_transactions
      imported = 0
      skipped = 0
      failures = []

      Array(truelayer_account.raw_transactions_payload).each do |transaction|
        if before_sync_start?(transaction)
          skipped += 1
          next
        end

        TruelayerEntry::Processor.new(transaction, truelayer_account: truelayer_account).process
        imported += 1
      rescue => e
        failures << { transaction_id: TruelayerAccount.transaction_id_for(transaction), error: "#{e.class}: #{e.message}" }
      end

      capture_failures(failures) if failures.any?
      { imported: imported, skipped: skipped, failed: failures.size, errors: failures }
    end

    # The start date is chosen at account setup. An unparseable timestamp is
    # left for the entry processor to report.
    def before_sync_start?(transaction)
      start = truelayer_account.truelayer_item.sync_start_date&.to_date
      return false unless start

      Date.iso8601(transaction.with_indifferent_access[:timestamp].to_s[0, 10]) < start
    rescue Date::Error
      false
    end

    def capture_failures(failures)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "#{failures.size} TrueLayer transaction(s) could not be imported",
        source: self.class.name,
        provider_key: "truelayer",
        family: truelayer_account.truelayer_item.family,
        account_provider: truelayer_account.account_provider,
        metadata: { account_id: truelayer_account.account_id, failed: failures.size, errors: failures.first(10) }
      )
      Rails.logger.warn "TruelayerAccount::Processor - #{failures.size} transaction(s) failed for #{truelayer_account.account_id}: #{failures.first[:error]}"
    end

    def report_exception(error)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(truelayer_account_id: truelayer_account.id)
      end
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for TrueLayer account #{truelayer_account.id}")
    end
end
