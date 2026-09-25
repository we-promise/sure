class MonobankAccount::Processor
  include CurrencyNormalizable

  SanitizedProcessingError = Class.new(StandardError)

  attr_reader :monobank_account

  # Build a processor for the given +monobank_account+.
  def initialize(monobank_account)
    @monobank_account = monobank_account
  end

  # Sync the linked account's balance and process its transactions. No-op when
  # the Monobank account isn't linked to a Sure account.
  def process
    unless monobank_account.current_account.present?
      Rails.logger.info "MonobankAccount::Processor - No linked account for monobank_account #{monobank_account.id}, skipping processing"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "MonobankAccount::Processor - Failed to process account monobank_account_id=#{monobank_account.id} error_class=#{e.class.name}"
    report_exception(e, "account")
    raise
  end

  private

    # Update the linked Sure account's balance/currency from the Monobank snapshot.
    def process_account!
      account = monobank_account.current_account
      # Own funds: MonobankAccount already subtracted the card's credit limit out of the
      # balance Monobank reports, so this can go straight onto the cash account.
      balance = monobank_account.current_balance || 0
      currency = parse_currency(monobank_account.currency) || account.currency || "UAH"

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    # Delegate to the transactions processor, capturing and logging failures.
    def process_transactions
      MonobankAccount::Transactions::Processor.new(monobank_account).process
    rescue => e
      report_exception(e, "transactions")
      Rails.logger.error "MonobankAccount::Processor - Failed to process transactions monobank_account_id=#{monobank_account.id} error_class=#{e.class.name}"
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process transactions",
        source: self.class.name,
        provider_key: "monobank",
        family: monobank_account.monobank_item.family,
        account_provider: monobank_account.account_provider,
        metadata: { monobank_account_id: monobank_account.id, error_class: e.class.name, error_message: e.message }
      )
      { success: false, failed: 1, errors: [ { error: I18n.t("monobank_item.errors.account_processing_failed") } ] }
    end

    # Report a processing error to Sentry with a sanitized message and tags.
    def report_exception(error, context)
      safe_error = SanitizedProcessingError.new("Monobank account processing failed")

      Sentry.capture_exception(safe_error) do |scope|
        scope.set_tags(
          monobank_account_id: monobank_account.id,
          context: context,
          error_class: error.class.name
        )
        scope.set_context(
          "monobank_account_processor",
          {
            monobank_account_id: monobank_account.id,
            context: context,
            error_class: error.class.name
          }
        )
      end
    end

    # CurrencyNormalizable hook: warn when a Monobank currency code is unrecognized.
    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Monobank account #{monobank_account.id}, falling back to account currency")
    end
end
