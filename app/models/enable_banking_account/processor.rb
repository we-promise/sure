class EnableBankingAccount::Processor
  class ProcessingError < StandardError; end
  include CurrencyNormalizable

  attr_reader :enable_banking_account

  def initialize(enable_banking_account)
    @enable_banking_account = enable_banking_account
  end

  def process
    unless enable_banking_account.current_account.present?
      Rails.logger.info "EnableBankingAccount::Processor - No linked account for enable_banking_account #{enable_banking_account.id}, skipping processing"
      return
    end

    Rails.logger.info "EnableBankingAccount::Processor - Processing enable_banking_account #{enable_banking_account.id} (uid #{enable_banking_account.uid})"

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "EnableBankingAccount::Processor - Failed to process account #{enable_banking_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    process_transactions
  end

  private

    def process_account!
      if enable_banking_account.current_account.blank?
        Rails.logger.error("Enable Banking account #{enable_banking_account.id} has no associated Account")
        return
      end

      account = enable_banking_account.current_account
      balance = enable_banking_account.current_balance

      # A nil current_balance means this sync's balance fetch did not succeed:
      # upsert_enable_banking_snapshot! clears it and only a successful
      # balance fetch repopulates it. Coercing nil to 0 here would persist a
      # zero balance (and a zero current_anchor valuation) onto a healthy
      # account whenever the provider has a transient failure, so leave the
      # account untouched instead.
      if balance.nil?
        Rails.logger.warn("EnableBankingAccount::Processor - No balance available for enable_banking_account #{enable_banking_account.id} (balance fetch failed or not yet run), skipping account update")
        return
      end

      available_credit = nil
      skip_balance_update = false

      # For liability accounts, ensure balance sign is correct.
      # For CreditCards, we expect the main balance to reflect the absolute outstanding debt
      # rather than available credit, to ensure net worth calculations handle the liability accurately.
      # Any available credit metrics (from limits) are instead stored safely as metadata on the Accountable.
      # Loans and CreditCards must always represent their outstanding balance as an absolute
      # positive debt amount, regardless of the API's reported sign, to ensure the BalanceSheet
      # calculates net worth accurately.
      if account.accountable_type == "Loan" || account.accountable_type == "CreditCard"
        # Standardize the raw balance to an absolute positive debt
        balance = balance.abs

        if account.accountable_type == "CreditCard"
          balance, available_credit, skip_balance_update = interpret_credit_card_balance(account, balance)
        end
      end

      currency = parse_currency(enable_banking_account.currency) || account.currency || "EUR"

      # Wrap both writes in a transaction so a failure on either rolls back both.
      ActiveRecord::Base.transaction do
        if account.accountable.present? && account.accountable.respond_to?(:available_credit=)
          account.accountable.update!(available_credit: available_credit)
        end

        if skip_balance_update
          account.update!(currency: currency)
        else
          account.update!(currency: currency, cash_balance: balance)

          # Use set_current_balance to create a current_anchor valuation entry.
          # This enables Balance::ReverseCalculator, which works backward from the
          # bank-reported balance — eliminating spurious cash adjustment spikes.
          result = account.set_current_balance(balance)
          raise ProcessingError, "Failed to set current balance: #{result.error}" unless result.success?
        end
      end

      # TODO: pass explicit window_start_date to sync_later to avoid full history recalculation on every sync
      # Currently relies on set_current_balance's implicit sync trigger; window params would require refactor
    end

    # Interprets the reported credit card balance based on the
    # treat_balance_as_available_credit flag.
    # Returns [balance, available_credit, skip_balance_update].
    def interpret_credit_card_balance(account, reported_balance)
      if enable_banking_account.treat_balance_as_available_credit?
        # In this mode the accountable's available_credit field holds the credit
        # limit: the API-provided one, or a user-entered value when the API
        # omits it. Writing the limit back (never the reported balance) keeps
        # the field stable across syncs so a manual limit is never clobbered.
        credit_limit = enable_banking_account.credit_limit.presence ||
                       account.accountable&.available_credit

        unless account.accountable.present?
          capture_debug_log("CreditCard accountable missing for account", account)
        end

        if credit_limit.present?
          # The API returns the available credit as the current balance, so the
          # outstanding debt is derived from the credit limit.
          # Use .max(0) to prevent synthetic debt on overpaid cards.
          outstanding_debt = [ credit_limit - reported_balance, 0 ].max

          [ outstanding_debt, credit_limit, false ]
        else
          # No credit limit from the API or the card's available credit field.
          # The reported balance is available credit, so the outstanding debt is
          # unknown. Keep the existing account balance instead of recording
          # available credit as debt.
          capture_debug_log("Cannot compute debt from available credit because no credit limit is set (API or manual)", account)

          [ nil, nil, true ]
        end
      else
        # Default behavior: API returns outstanding debt
        available_credit = if enable_banking_account.credit_limit.present?
          [ enable_banking_account.credit_limit - reported_balance, 0 ].max
        elsif account.accountable&.available_credit.present?
          # No limit from API, but we have stored available_credit metadata
          account.accountable.available_credit
        end

        [ reported_balance, available_credit, false ]
      end
    end

    def capture_debug_log(message, account)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: message,
        source: "EnableBankingAccount::Processor",
        provider_key: "enable_banking",
        account: account,
        account_provider: account.account_providers.find_by(provider_type: "EnableBankingAccount"),
        metadata: {
          enable_banking_account_id: enable_banking_account.id,
          enable_banking_item_id: enable_banking_account.enable_banking_item_id
        }
      )
    end

    def process_transactions
      EnableBankingAccount::Transactions::Processor.new(enable_banking_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          enable_banking_account_id: enable_banking_account.id,
          context: context
        )
      end
    end
end
