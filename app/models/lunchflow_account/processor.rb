class LunchflowAccount::Processor
  include CurrencyNormalizable

  attr_reader :lunchflow_account

  def initialize(lunchflow_account)
    @lunchflow_account = lunchflow_account
  end

  def process
    unless lunchflow_account.current_account.present?
      Rails.logger.info "LunchflowAccount::Processor - No linked account for lunchflow_account #{lunchflow_account.id}, skipping processing"
      return
    end

    Rails.logger.info "LunchflowAccount::Processor - Processing lunchflow_account #{lunchflow_account.id} (account #{lunchflow_account.account_id})"

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "LunchflowAccount::Processor - Failed to process account #{lunchflow_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    process_transactions
    process_investments
  end

  private

    def process_account!
      if lunchflow_account.current_account.blank?
        Rails.logger.error("Lunchflow account #{lunchflow_account.id} has no associated Account")
        return
      end

      # Update account balance from latest Lunchflow data
      account = lunchflow_account.current_account
      balance = lunchflow_account.current_balance

      # A nil current_balance means this sync's balance fetch did not succeed:
      # upsert_lunchflow_snapshot! clears it (the accounts endpoint carries no
      # balance) and only a successful balance fetch repopulates it. Coercing
      # nil to 0 here would persist a zero balance (and the USD currency
      # fallback) onto a healthy account whenever the provider has a
      # transient failure, so leave the account untouched instead.
      if balance.nil?
        Rails.logger.warn("LunchflowAccount::Processor - No balance available for lunchflow_account #{lunchflow_account.id} (balance fetch failed or not yet run), skipping account update")
        return
      end

      # LunchFlow balance convention matches our app convention:
      # - Positive balance = debt (you owe money)
      # - Negative balance = credit balance (bank owes you, e.g., overpayment)
      # No sign conversion needed - pass through as-is (same as Plaid)
      #
      # Exception: CreditCard and Loan accounts return inverted signs
      # Provider returns negative for positive balance, so we negate it
      #
      # Some banks (e.g. Halifax via the Lloyds connection) report a credit
      # card's remaining available credit instead. When the user flags the card
      # as such, derive the debt from the card limit they entered.
      if account.accountable_type == "CreditCard" && lunchflow_account.treat_balance_as_available_credit?
        balance = debt_from_available_credit(account, balance)
        return if balance.nil?
      elsif account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = -balance
      end

      # Normalize currency with fallback chain: parsed lunchflow currency -> existing account currency -> USD
      currency = parse_currency(lunchflow_account.currency) || account.currency || "USD"

      # Update account balance
      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    def process_transactions
      LunchflowAccount::Transactions::Processor.new(lunchflow_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def process_investments
      # Only process holdings for investment/crypto accounts with holdings support
      return unless lunchflow_account.holdings_supported?
      return unless [ "Investment", "Crypto" ].include?(lunchflow_account.current_account&.accountable_type)

      LunchflowAccount::Investments::HoldingsProcessor.new(lunchflow_account).process
    rescue => e
      report_exception(e, "holdings")
    end

    # Lunch Flow does not report a credit limit, so in available-credit mode
    # the card's Available credit field holds the user-entered limit. A
    # reported amount above the limit is an overpayment, which stays a
    # negative (credit) balance like the default path. Returns nil when no
    # limit is set: the debt is then unknown, so the existing balance is kept
    # rather than recording available credit as debt.
    def debt_from_available_credit(account, reported_available_credit)
      credit_limit = account.accountable&.available_credit
      return credit_limit - reported_available_credit if credit_limit&.positive?

      message = "Cannot compute debt from available credit because no credit limit is set; keeping previous Sure account balance"
      Rails.logger.warn("LunchflowAccount::Processor - #{message} (lunchflow_account #{lunchflow_account.id})")
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: message,
        source: self.class.name,
        provider_key: "lunchflow",
        account: account,
        account_provider: lunchflow_account.account_provider,
        metadata: { lunchflow_account_id: lunchflow_account.id }
      )
      nil
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          lunchflow_account_id: lunchflow_account.id,
          context: context
        )
      end
    end
end
