class MercuryAccount::Processor
  include CurrencyNormalizable

  attr_reader :mercury_account

  def initialize(mercury_account)
    @mercury_account = mercury_account
  end

  def process
    unless mercury_account.current_account.present?
      Rails.logger.info "MercuryAccount::Processor - No linked account for mercury_account #{mercury_account.id}, skipping processing"
      return
    end

    Rails.logger.info "MercuryAccount::Processor - Processing mercury_account #{mercury_account.id} (account #{mercury_account.account_id})"

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "MercuryAccount::Processor - Failed to process account #{mercury_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    process_transactions
  end

  private

    def process_account!
      if mercury_account.current_account.blank?
        Rails.logger.error("Mercury account #{mercury_account.id} has no associated Account")
        return
      end

      # Update account balance from latest Mercury data
      account = mercury_account.current_account
      balance = mercury_account.current_balance || 0

      # Mercury balance convention:
      # - currentBalance is the actual balance of the account
      # - For checking/savings (Depository): positive = money in account
      # - For credit lines: positive = money owed, negative = credit available
      #
      # No sign conversion needed for Depository accounts
      # Credit accounts are not typically offered by Mercury, but handle just in case
      if account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = -balance
      end

      # Mercury is US-only, always USD
      currency = "USD"

      # Update account balance
      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    def process_transactions
      MercuryAccount::Transactions::Processor.new(mercury_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          mercury_account_id: mercury_account.id,
          context: context
        )
      end
    end
end
