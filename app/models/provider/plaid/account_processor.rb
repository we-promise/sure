# Per-account orchestrator. Direct port of PlaidAccount::Processor with the
# legacy AccountProvider/plaid_account_id account-resolution path removed —
# the Provider::Account already owns its account_id link via build_sure_account
# (called during the link/setup flow), so by the time we reach here the
# account exists and our job is enrichment + balance + sub-processor dispatch.
class Provider::Plaid::AccountProcessor
  TYPE_MAPPING = Provider::Plaid::Adapter::TYPE_MAPPING

  def initialize(provider_account)
    @provider_account = provider_account
  end

  # Steps mirror the Plaid product surface. account! is the gating step —
  # if it fails we abort. Each subsequent step can fail independently.
  def process
    process_account!
    process_transactions
    process_investments
    process_liabilities
  end

  private
    attr_reader :provider_account

    def account
      provider_account.account
    end

    def family
      provider_account.provider_connection.family
    end

    def security_resolver
      @security_resolver ||= Provider::Plaid::Investments::SecurityResolver.new(provider_account)
    end

    def process_account!
      Provider::Account.transaction do
        # The account already exists — created via provider_account.build_sure_account
        # during the link flow. Enrich its attributes from the latest payload,
        # update balance + cash_balance, and persist.
        plaid_type    = provider_account.external_type
        plaid_subtype = provider_account.external_subtype

        # Enrich name (user-overrideable, locked-aware)
        account.enrich_attributes({ name: provider_account.external_name }, source: "plaid")

        # Enrich subtype on the accountable
        sure_subtype = TYPE_MAPPING.dig(plaid_type, :subtype_mapping, plaid_subtype) || "other"
        account.accountable.enrich_attributes({ subtype: sure_subtype }, source: "plaid")

        account.assign_attributes(
          balance:      balance_calculator.balance,
          currency:     provider_account.currency,
          cash_balance: balance_calculator.cash_balance
        )
        account.save!

        # Anchor balance valuation in event-sourced ledger
        account.set_current_balance(balance_calculator.balance)
      end
    end

    def process_transactions
      Provider::Plaid::Transactions::Processor.new(provider_account).process
    rescue => e
      report_exception(e)
    end

    def process_investments
      Provider::Plaid::Investments::TransactionsProcessor.new(provider_account, security_resolver: security_resolver).process
      Provider::Plaid::Investments::HoldingsProcessor.new(provider_account, security_resolver: security_resolver).process
    rescue => e
      report_exception(e)
    end

    def process_liabilities
      case [ provider_account.external_type, provider_account.external_subtype ]
      when [ "credit", "credit card" ]
        Provider::Plaid::Liabilities::CreditProcessor.new(provider_account).process
      when [ "loan", "mortgage" ]
        Provider::Plaid::Liabilities::MortgageProcessor.new(provider_account).process
      when [ "loan", "student" ]
        Provider::Plaid::Liabilities::StudentLoanProcessor.new(provider_account).process
      end
    rescue => e
      report_exception(e)
    end

    def balance_calculator
      @balance_calculator ||= if provider_account.external_type == "investment"
        Provider::Plaid::Investments::BalanceCalculator.new(provider_account, security_resolver: security_resolver)
      else
        balances = provider_account.raw_payload&.dig("balances") || {}
        bal = balances["current"] || balances["available"] || 0
        OpenStruct.new(balance: bal, cash_balance: bal)
      end
    end

    def report_exception(error)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(provider_account_id: provider_account.id)
      end
    end
end
