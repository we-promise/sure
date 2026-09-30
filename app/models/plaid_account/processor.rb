class PlaidAccount::Processor
  include PlaidAccount::TypeMappable

  attr_reader :plaid_account

  def initialize(plaid_account)
    @plaid_account = plaid_account
  end

  # Each step represents a different Plaid API endpoint / "product"
  #
  # Processing the account is the first step and if it fails, we halt the entire processor
  # Each subsequent step can fail independently, but we continue processing the rest of the steps
  def process
    process_account!
    process_transactions
    process_investments
    process_liabilities
  end

  private
    def family
      plaid_account.plaid_item.family
    end

    # Shared securities reader and resolver
    def security_resolver
      @security_resolver ||= PlaidAccount::Investments::SecurityResolver.new(plaid_account)
    end

    def process_account!
      PlaidAccount.transaction do
        # Find existing account through account_provider or legacy plaid_account_id
        account_provider = AccountProvider.find_by(provider: plaid_account)
        account = if account_provider
          account_provider.account
        else
          # Legacy fallback: find by plaid_account_id if it still exists
          family.accounts.find_by(plaid_account_id: plaid_account.id)
        end

        # Initialize new account if not found
        if account.nil?
          # Accounts are created here, inside the sync job, where Current.user
          # is nil -- so Account#assign_default_owner would fall back to the
          # family's first admin and silently hand a member's own connection to
          # someone else. Seed the owner from the item that produced it, before
          # the enrich_attributes calls below run validations.
          account = family.accounts.new(owner: plaid_account.plaid_item&.owner)
          account.accountable = map_accountable(plaid_account.plaid_type)
        end

        # Create or assign the accountable if needed
        if account.accountable.nil?
          accountable = map_accountable(plaid_account.plaid_type)
          account.accountable = accountable
        end

        # Name and subtype are the attributes a user can override for Plaid accounts
        # Use enrichable pattern to respect locked attributes
        account.enrich_attributes(
          {
            name: plaid_account.name
          },
          source: "plaid"
        )

        # Enrich subtype on the accountable, respecting locks
        account.accountable.enrich_attributes(
          {
            subtype: map_subtype(plaid_account.plaid_type, plaid_account.plaid_subtype)
          },
          source: "plaid"
        )

        balance_date = self.balance_date

        # A snapshot dated behind the anchor the account already holds is a
        # correction to a day gone by, recorded on its own date below; the
        # cached balance and cash stay as they are, since they describe now.
        snapshot_behind_anchor = account.persisted? && account.has_current_anchor? &&
          account.current_anchor_date > balance_date

        attributes = { currency: plaid_account.currency }
        unless snapshot_behind_anchor
          attributes[:balance] = balance_calculator.balance
          attributes[:cash_balance] = balance_calculator.cash_balance
        end
        account.assign_attributes(attributes)

        new_account = account.new_record?
        account.save!

        account.auto_share_with_family! if new_account && account.family.share_all_by_default?

        # Create account provider link if it doesn't exist
        unless account_provider
          AccountProvider.find_or_create_by!(
            account: account,
            provider: plaid_account,
            provider_type: "PlaidAccount"
          )
        end

        # Create or update the current balance anchor valuation for event-sourced ledger
        # Note: This is a partial implementation. In the future, we'll introduce HoldingValuation
        # to properly track the holdings vs. cash breakdown, but for now we're only tracking
        # the total balance in the current anchor. The cash_balance field on the account model
        # is still being used for the breakdown.
        account.set_current_balance(balance_calculator.balance, date: balance_date)
      end
    end

    def process_transactions
      PlaidAccount::Transactions::Processor.new(plaid_account).process
    rescue => e
      report_exception(e)
    end

    def process_investments
      PlaidAccount::Investments::TransactionsProcessor.new(plaid_account, security_resolver: security_resolver).process
      PlaidAccount::Investments::HoldingsProcessor.new(plaid_account, security_resolver: security_resolver).process
    rescue => e
      report_exception(e)
    end

    def process_liabilities
      type = plaid_account.plaid_type
      subtype = plaid_account.plaid_subtype

      # The `credit` branch is deliberately subtype-agnostic, mirroring
      # AccountsSnapshot#can_fetch_liabilities?. Matching only "credit card"
      # here meant a credit/paypal account fetched and stored the raw
      # liabilities response but never updated minimum_payment or apr, leaving
      # the user-visible figures blank.
      if type == "credit"
        PlaidAccount::Liabilities::CreditProcessor.new(plaid_account).process
      elsif type == "loan" && subtype == "mortgage"
        PlaidAccount::Liabilities::MortgageProcessor.new(plaid_account).process
      elsif type == "loan" && subtype == "student"
        PlaidAccount::Liabilities::StudentLoanProcessor.new(plaid_account).process
      end
    rescue => e
      report_exception(e)
    end

    # Plaid dates each holding with the institution's price date, which for a
    # sync run before the close is the previous session's; the total it reports
    # alongside is as of that same date. Anchoring that total on today would
    # set it against holdings later repriced for today, and the difference
    # would read as cash on every day in between -- the shift #3815 removed
    # from IBKR. The anchor goes on the newest date the holdings carry; a
    # snapshot with no dated holdings, or one dated ahead of today, is today's.
    def balance_date
      return Date.current unless plaid_account.plaid_type == "investment"

      newest = holdings.filter_map { |holding| parse_date(holding["institution_price_as_of"]) }.max
      return Date.current if newest.nil? || newest > Date.current

      newest
    end

    def holdings
      plaid_account.raw_holdings_payload&.dig("holdings") || []
    end

    def parse_date(value)
      return nil if value.blank?
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def balance_calculator
      if plaid_account.plaid_type == "investment"
        @balance_calculator ||= PlaidAccount::Investments::BalanceCalculator.new(plaid_account, security_resolver: security_resolver)
      else
        balance = plaid_account.current_balance || plaid_account.available_balance || 0

        # We don't currently distinguish "cash" vs. "non-cash" balances for non-investment accounts.
        OpenStruct.new(
          balance: balance,
          cash_balance: balance
        )
      end
    end

    def report_exception(error)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(plaid_account_id: plaid_account.id)
      end
    end
end
