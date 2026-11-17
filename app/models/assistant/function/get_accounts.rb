class Assistant::Function::GetAccounts < Assistant::Function
  class << self
    def name
      "get_accounts"
    end

    def description
      <<~INSTRUCTIONS
        Use this to see what accounts the user has along with their current balances.

        Returns account ids. Use them for account_ids filters in other tools.

        Loan and credit card accounts also carry a `terms` object with the
        borrowing terms the user recorded (rate, term, monthly payment, APR,
        minimum payment). A key is absent when the user never entered it, so
        treat a missing key as unknown rather than as zero.

        A loan's `interest_rate` is the rate in force on `as_of_date`. When a
        variable-rate loan's recorded rate changes have moved it,
        `base_interest_rate` is the rate the loan started at.

        For a fixed-rate loan, `monthly_payment` is the contracted repayment,
        still reported after the term has ended. For a variable-rate loan it is
        the next scheduled repayment on or after `as_of_date`, already sized at
        every change recorded to take effect by that payment, so it can reflect
        a change `interest_rate` does not show yet. It is absent once every
        scheduled payment is past. A change the user has not recorded is not
        reflected in either field.

        Note on `terms.available_credit`: providers disagree on its meaning
        (some report the credit limit, others the remaining credit), so confirm
        with the user before reasoning about headroom on a linked card.

        Pass include_balance_series: true only when the user asks about balance
        history; the series is omitted by default to keep responses small.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        include_balance_series: {
          type: "boolean",
          description: "Include a historical balance series per account (defaults to false)"
        },
        series_period: {
          type: "string",
          enum: Period::PERIODS.keys,
          description: "Period for the balance series (defaults to last_365_days)"
        }
      }
    )
  end

  def call(params = {})
    include_series = params["include_balance_series"] == true
    period = series_period(params)
    as_of_date = Date.current

    {
      as_of_date: as_of_date,
      accounts: accounts_scope(include_series).map do |account|
        payload = {
          id: account.id,
          name: account.name,
          balance: account.balance,
          currency: account.currency,
          balance_formatted: account.balance_money.format,
          classification: account.classification,
          type: account.accountable_type,
          subtype: account.subtype,
          start_date: account.start_date,
          is_linked: account.linked?,
          provider: account.provider_name,
          status: account.status
        }

        terms = account_terms(account, as_of_date)
        payload[:terms] = terms if terms.present?

        if include_series
          series = historical_balances(account, period)
          payload[:historical_balances] = series if series
        end
        payload
      end
    }
  end

  private
    # No balances preload: the series goes through Balance::ChartSeriesBuilder,
    # which runs its own query keyed by account ids.
    def accounts_scope(_include_series)
      user.accessible_accounts.visible.includes(:account_providers, :accountable)
    end

    # The accountable record holds the only borrowing terms Sure stores, and
    # this tool used to drop the delegated record entirely, so an assistant
    # asked "what is my loan costing me" had nothing to answer with even though
    # the rate was sitting in the database. Only the types that carry financial
    # terms are serialized; the rest (Depository, Property, ...) return nil and
    # the key is omitted.
    def account_terms(account, as_of_date)
      case account.accountable
      when Loan then loan_terms(account.accountable, as_of_date)
      when CreditCard then credit_card_terms(account.accountable)
      end
    end

    # `compact` throughout: a nil rate must read as "the user never entered it",
    # never as zero. An entirely empty hash is dropped by the caller.
    #
    # Rate and repayment are read the way the loan's Overview tab reads them, so
    # the assistant never quotes a figure the user's own loan page contradicts.
    # Once a variable loan has a recorded rate change, the `interest_rate` column
    # is only the rate it started at, not the one it charges.
    def loan_terms(loan, as_of_date)
      interest_rate = loan.current_variable_rate(as_of_date)
      monthly_payment = payment_in_force(loan, as_of_date)
      original_balance = loan.original_balance

      {
        interest_rate: interest_rate,
        base_interest_rate: (loan.interest_rate if loan.interest_rate != interest_rate),
        rate_type: loan.rate_type,
        term_months: loan.term_months,
        monthly_payment: monthly_payment&.amount,
        monthly_payment_formatted: monthly_payment&.format,
        original_balance: original_balance&.amount,
        original_balance_formatted: original_balance&.format
      }.compact
    end

    # Loan#monthly_payment stays nil for a variable loan, which has no single
    # contracted repayment. It always has the next one, though, sized at every
    # change recorded before it, and that is what the Overview tab quotes. Nil
    # when there is no schedule or it has run out, so the key is omitted rather
    # than reported as zero.
    def payment_in_force(loan, as_of_date)
      return loan.monthly_payment unless loan.variable_rate_type?

      loan.amortization_schedule&.payment_in_force(as_of_date)
    end

    def credit_card_terms(credit_card)
      {
        apr: credit_card.apr,
        minimum_payment: credit_card.minimum_payment,
        annual_fee: credit_card.annual_fee,
        available_credit: credit_card.available_credit,
        expiration_date: credit_card.expiration_date
      }.compact
    end

    def historical_balances(account, period)
      effective_start = [ account.start_date, period.start_date ].max
      # An account whose start date lies beyond the period (start_date derives
      # from the first entry, which can be future-dated) simply has no series;
      # it must not fail the whole accounts listing.
      return nil if effective_start > period.end_date

      effective = Period.custom(start_date: effective_start, end_date: period.end_date)
      balance_series = account.balance_series(period: effective, interval: effective.interval)

      to_ai_time_series(balance_series)
    end

    def series_period(params)
      key = params["series_period"].to_s

      Period.valid_key?(key) ? Period.from_key(key) : Period.from_key("last_365_days")
    end
end
