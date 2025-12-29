class CoinstatsAccount::Processor
  include CurrencyNormalizable

  attr_reader :coinstats_account

  def initialize(coinstats_account)
    @coinstats_account = coinstats_account
  end

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

    def process_transactions
      CoinstatsAccount::Transactions::Processor.new(coinstats_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          coinstats_account_id: coinstats_account.id,
          context: context
        )
      end
    end
end
