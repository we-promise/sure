# Processes a CoinStats account to update balance and import transactions.
# Updates the linked Account balance and delegates to transaction processor.
class CoinstatsAccount::Processor
  include CurrencyNormalizable

  attr_reader :coinstats_account

  # @param coinstats_account [CoinstatsAccount] Account to process
  def initialize(coinstats_account)
    @coinstats_account = coinstats_account
  end

  # Updates account balance and processes transactions.
  # Skips processing if no linked account exists.
  def process
    unless coinstats_account.current_account.present?
      Rails.logger.info "CoinstatsAccount::Processor - No linked account for coinstats_account #{coinstats_account.id}, skipping processing"
      return
    end

    Rails.logger.info "CoinstatsAccount::Processor - Processing coinstats_account #{coinstats_account.id}"

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "CoinstatsAccount::Processor - Failed to process account #{coinstats_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    process_transactions
  end

  private

    # Updates the linked Account with current balance from CoinStats.
    def process_account!
      account = coinstats_account.current_account
      balance = coinstats_account.current_balance || 0
      currency = parse_currency(coinstats_account.currency) || account.currency || "USD"

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    # Delegates transaction processing to the specialized processor.
    def process_transactions
      CoinstatsAccount::Transactions::Processor.new(coinstats_account).process
    rescue StandardError => e
      report_exception(e, "transactions")
    end

    # Reports errors to Sentry with context tags.
    # @param error [Exception] The error to report
    # @param context [String] Processing context (e.g., "account", "transactions")
    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          coinstats_account_id: coinstats_account.id,
          context: context
        )
      end
    end
end
