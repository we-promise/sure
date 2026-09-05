class Assistant::Function::GetLiabilities < Assistant::Function
  class << self
    def name
      "get_liabilities"
    end

    def description
      <<~INSTRUCTIONS
        Lists what the user owes (loans, credit cards, other liabilities) with
        the borrowing terms and a repayment projection for each.

        Use this instead of get_accounts whenever the question is about debt:
        what a loan costs per month, when it is paid off, how much interest is
        left, or whether paying it down early is worth it.

        Each entry carries:
        - `terms`: the contract as the user recorded it. `interest_rate` is the
          nominal rate; `apr` is the all-in rate (French TAEG) and is NOT the
          rate used to compute the schedule, so never present them as the same
          number.
        - `schedule`: what follows from those terms. `monthly_payment` is the
          instalment, `insurance_monthly_amount` is billed on top of it, and
          `total_monthly_cost` is what actually leaves the account.
          `remaining_payments` and `payoff_date` are computed from the LIVE
          balance, so they already reflect any overpayment.
        - `unavailable`: the figures that could not be computed, each with the
          reason. Read it before saying a number is unknown, and tell the user
          which field to fill in rather than guessing.

        Pass include_amortization: true to add the derived month-by-month
        principal AND a comparison against the balance history Sure recorded.
        A liability's stored balance only moves when an entry lands on the loan
        account, so a loan repaid by direct debit from a current account sits
        frozen between manual valuations and then jumps. When
        `history_comparison.largest_gap.difference` is large and positive, the
        user's net worth curve understates the repayment progress they actually
        made, and that is worth telling them.

        A missing key means the user never entered that term. Never substitute
        zero for it, and never infer a rate from the balance history.
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
        include_amortization: {
          type: "boolean",
          description: "Include the derived month-by-month principal schedule and how it compares with the recorded balance history (defaults to false; it is large)"
        }
      }
    )
  end

  def call(params = {})
    accounts = liability_accounts
    amortization = params["include_amortization"] == true

    {
      as_of_date: Date.current,
      liabilities: accounts.map { |account| serialize(account, amortization: amortization) },
      totals_by_currency: totals_by_currency(accounts)
    }
  end

  private
    def liability_accounts
      user.accessible_accounts
          .visible
          .where(accountable_type: %w[Loan CreditCard OtherLiability])
          .includes(:accountable)
          .to_a
    end

    def serialize(account, amortization: false)
      payload = {
        id: account.id,
        name: account.name,
        type: account.accountable_type,
        subtype: account.subtype,
        balance: account.balance,
        balance_formatted: account.balance_money.format,
        currency: account.currency
      }

      terms = terms_for(account)
      payload[:terms] = terms if terms.present?

      schedule = schedule_for(account)
      payload[:schedule] = schedule if schedule.present?

      unavailable = unavailable_for(account)
      payload[:unavailable] = unavailable if unavailable.present?

      payload[:amortization] = amortization_for(account) if amortization

      payload
    end

    # Opt-in: the schedule of a 20-year mortgage is 240 rows, which is not what
    # most questions need. The divergence summary is the part that matters and
    # is small, so it is emitted even when the full series is trimmed.
    def amortization_for(account)
      return { available: false, reason: "Not a loan." } unless account.accountable.is_a?(Loan)

      schedule = Loan::AmortizationSchedule.new(account.accountable)
      return { available: false, reason: schedule.unavailable_reason } unless schedule.available?

      payload = {
        available: true,
        anchored_at_origination: schedule.anchored_at_origination?,
        starts_on: schedule.start_date,
        payoff_date: schedule.payoff_date,
        total_interest: schedule.total_interest.round(2),
        points: schedule.points.map { |point| { date: point.date, balance: point.balance } }
      }

      unless schedule.anchored_at_origination?
        payload[:note] = "No origination date and original balance are recorded, so this schedule runs forward " \
                         "from today only and cannot be compared with the recorded history."
        return payload
      end

      payload.merge(recorded_history_comparison(schedule))
    end

    # The point of the whole exercise. A liability's stored balance only moves
    # when an entry lands on the loan account, so a loan repaid by direct debit
    # from a checking account sits frozen between manual valuations and then
    # jumps. Quantifying the gap is what tells the user their net-worth curve
    # understates the progress they actually made.
    def recorded_history_comparison(schedule)
      divergences = schedule.divergences
      return { history_comparison: { available: false, reason: "No recorded balances in the schedule's range." } } if divergences.empty?

      worst = divergences.max_by { |divergence| divergence.difference.abs }

      {
        history_comparison: {
          available: true,
          months_compared: divergences.size,
          largest_gap: {
            date: worst.date,
            recorded_balance: worst.recorded,
            expected_balance: worst.expected,
            difference: worst.difference
          },
          note: "`recorded_balance` is what the net worth history shows; `expected_balance` is what the loan's " \
                "own terms imply. A persistent positive difference means the recorded history understates the " \
                "repayment progress, because a liability's stored balance only moves when an entry lands on the " \
                "loan account itself.",
          monthly: divergences.map do |divergence|
            { date: divergence.date, recorded: divergence.recorded, expected: divergence.expected, difference: divergence.difference }
          end
        }
      }
    end

    def terms_for(account)
      case account.accountable
      when Loan then loan_terms(account.accountable)
      when CreditCard then credit_card_terms(account.accountable)
      end
    end

    def loan_terms(loan)
      {
        interest_rate: loan.interest_rate,
        rate_type: loan.rate_type,
        apr: loan.apr,
        term_months: loan.term_months,
        origination_date: loan.origination_date,
        maturity_date: loan.maturity_date,
        insurance_monthly_amount: loan.insurance_monthly_amount,
        early_repayment_terms: loan.early_repayment_terms.presence,
        original_balance: loan.original_balance&.amount
      }.compact
    end

    def credit_card_terms(card)
      {
        apr: card.apr,
        minimum_payment: card.minimum_payment,
        annual_fee: card.annual_fee,
        available_credit: card.available_credit,
        expiration_date: card.expiration_date
      }.compact
    end

    def schedule_for(account)
      return nil unless account.accountable.is_a?(Loan)

      loan = account.accountable
      payment = loan.effective_payment
      total_cost = loan.total_monthly_cost
      remaining = loan.remaining_payments
      interest = loan.remaining_interest

      {
        monthly_payment: payment&.amount,
        monthly_payment_formatted: payment&.format,
        # Stated explicitly rather than left for the caller to add up: an
        # assistant quoting the instalment alone understates what the user
        # actually pays every month by the whole premium.
        insurance_monthly_amount: loan.insurance_monthly_amount,
        total_monthly_cost: total_cost&.amount,
        total_monthly_cost_formatted: total_cost&.format,
        remaining_payments: remaining,
        payoff_date: loan.payoff_date,
        remaining_interest: interest&.amount,
        remaining_interest_formatted: interest&.format
      }.compact
    end

    # Naming what is missing and why is the point. Without it an assistant
    # reports "unknown" and the user has no idea which field would fix it.
    def unavailable_for(account)
      return nil unless account.accountable.is_a?(Loan)

      loan = account.accountable
      reasons = {}

      if loan.effective_payment.nil?
        reasons[:monthly_payment] =
          if loan.rate_type.present? && loan.rate_type != "fixed"
            "Only a fixed-rate loan has a computable instalment. Ask the user for the actual " \
            "monthly payment and record it in the loan's \"Actual monthly payment\" field."
          else
            "Needs interest_rate, term_months and rate_type \"fixed\", or an explicit scheduled payment."
          end
      elsif loan.remaining_payments.nil?
        reasons[:remaining_payments] =
          "The monthly payment does not cover the monthly interest at this rate and balance, " \
          "so the loan never amortizes. Check the rate and the payment with the user."
      end

      reasons[:apr] = "The all-in rate (TAEG) was never recorded." if loan.apr.blank?

      reasons.presence
    end

    def totals_by_currency(accounts)
      accounts.group_by(&:currency).transform_values do |group|
        total = group.sum { |account| account.balance.to_d }

        {
          amount: total,
          formatted: Money.new(total, group.first.currency).format,
          account_count: group.size
        }
      end
    end
end
