class UpAccount::Processor
  include CurrencyNormalizable

  SanitizedProcessingError = Class.new(StandardError)

  attr_reader :up_account

  # Build a processor for the given +up_account+.
  def initialize(up_account)
    @up_account = up_account
  end

  # Sync the linked account's balance and process its transactions. No-op when
  # the Up account isn't linked to a Sure account.
  def process
    unless up_account.current_account.present?
      Rails.logger.info "UpAccount::Processor - No linked account for up_account #{up_account.id}, skipping processing"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "UpAccount::Processor - Failed to process account up_account_id=#{up_account.id} error_class=#{e.class.name}"
    report_exception(e, "account")
    raise
  end

  private

    # Update the linked Sure account's balance/currency from the Up snapshot.
    def process_account!
      account = up_account.current_account
      balance = up_account.current_balance || 0

      # Loan balances are stored as positive debt in Sure regardless of Up's sign.
      balance = balance.abs if account.accountable_type == "Loan"
      currency = parse_currency(up_account.currency) || account.currency || "AUD"

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    # Delegate to the transactions processor, capturing and logging failures.
    def process_transactions
      UpAccount::Transactions::Processor.new(up_account).process
    rescue => e
      report_exception(e, "transactions")
      Rails.logger.error "UpAccount::Processor - Failed to process transactions up_account_id=#{up_account.id} error_class=#{e.class.name}"
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process transactions",
        source: self.class.name,
        provider_key: "up",
        family: up_account.up_item.family,
        account_provider: up_account.account_provider,
        metadata: { up_account_id: up_account.id, error_class: e.class.name, error_message: e.message }
      )
      { success: false, failed: 1, errors: [ { error: I18n.t("up_item.errors.account_processing_failed") } ] }
    end

    # Report a processing error to Sentry with a sanitized message and tags.
    def report_exception(error, context)
      safe_error = SanitizedProcessingError.new("Up account processing failed")

      Sentry.capture_exception(safe_error) do |scope|
        scope.set_tags(
          up_account_id: up_account.id,
          context: context,
          error_class: error.class.name
        )
        scope.set_context(
          "up_account_processor",
          {
            up_account_id: up_account.id,
            context: context,
            error_class: error.class.name
          }
        )
      end
    end

    # CurrencyNormalizable hook: warn when an Up currency code is unrecognized.
    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Up account #{up_account.id}, falling back to account currency")
    end
end
