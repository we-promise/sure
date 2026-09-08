class UI::Loan::RateChangeTable < ApplicationComponent
  # FR-405: the scheduled rate changes a borrower has recorded, in the shape a
  # lender letter uses -- what you pay now, what you will pay, and from when.
  #
  # Future changes only. A change already in effect is not news; it is the
  # current rate, and the card above this table already states it.
  #
  # Every "new repayment" figure re-amortises the balance projected for that
  # effective date over the payments still remaining to the ORIGINAL maturity.
  #
  # That balance comes from `Loan::PayoffProjection`, which runs forward from
  # TODAY'S ACTUAL BALANCE -- deliberately NOT from the contracted schedule.
  # #15 says to use "the simulated balance at the effective date, which the
  # engine produces for free", and the contracted schedule is the cheaper
  # reading of that. It is also the wrong one: `current_minimum_payment` is
  # computed on today's actual balance, so pairing it with a contracted-schedule
  # balance puts two different principals in one row. Measured on a loan whose
  # actual balance had drifted from its contracted trajectory, that made a
  # 0.25pp rate CUT appear to save $319/month when the rate itself accounts for
  # ~$60 of it; the rest was the balance base silently changing between the two
  # columns. Both columns now sit on the same projection.
  attr_reader :loan, :as_of

  def initialize(loan:, as_of: Date.current)
    @loan = loan
    @as_of = as_of
  end

  def render?
    rows.any?
  end

  def rows
    # A fixed-rate loan can still carry rate rows: #14 keeps a loan's rate
    # history when its type changes rather than silently discarding it. Those
    # rows are history, not a forthcoming change, and this table is rendered on
    # every loan's schedule tab.
    return [] unless loan.variable_rate_type?

    @rows ||= future_rate_changes.filter_map do |effective_date, new_rate|
      row_index = projected_row_index_at(effective_date)
      next if row_index.nil?

      balance = interest_bearing_projected_balance(row_index)
      next unless balance.positive?

      # Payments remaining to the ORIGINAL maturity, counted inclusively so the
      # boundary payment whose opening balance was just used is also one of the
      # periods it is spread over. Counting payments strictly after the
      # effective date dropped exactly one whenever a change landed on a
      # payment date.
      #
      # Deliberately NOT `projected_rows.length - row_index`: that is the
      # projection's own term, which runs until the balance clears at the
      # current repayment, not to the contracted maturity. Using it re-amortised
      # over the wrong term and moved this quote by hundreds of dollars.
      remaining = schedule.remaining_payment_count(as_of: effective_date, including_on_date: true)
      next unless remaining.positive?

      {
        effective_date: effective_date,
        current_rate: current_rate,
        new_rate: BigDecimal(new_rate.to_s),
        balance: Money.new(balance, currency),
        current_payment: current_payment,
        new_payment: Money.new(
          Loan::AmortizationMath.level_payment(
            balance: balance,
            monthly_rate: Loan.monthly_rate(new_rate),
            remaining_payments: remaining,
            currency_precision: Money::Currency.new(currency).default_precision
          ),
          currency
        )
      }
    end
  end

  def current_rate
    @current_rate ||= BigDecimal(loan.current_variable_rate(as_of).to_s)
  end

  def current_payment
    @current_payment ||= loan.current_minimum_payment(as_of: as_of)
  end

  private

    def schedule
      @schedule ||= loan.amortization_schedule
    end

    def currency
      loan.account.currency
    end

    # `Loan#variable_rates` already returns entries in date order, so this
    # preserves that ordering. One parse per entry, not two (Codacy, #79).
    def future_rate_changes
      loan.variable_rates.filter_map do |date, rate|
        effective_date = Date.iso8601(date.to_s)
        [ effective_date, rate ] if effective_date > as_of
      end
    end

    # Index of the first projected payment on or after the effective date.
    # Half-open to match the accrual windows (C7): a change effective on a
    # payment date governs the period that OPENS on it.
    def projected_row_index_at(effective_date)
      projected_rows.index { |payment| payment[:payment_date] >= effective_date }
    end

    # Net of any linked offset, so this sits on the same basis as
    # `current_minimum_payment`. The projection's `beginning_balance` is the
    # GROSS loan balance -- an offset reduces the interest charged, not the
    # principal owed -- so quoting a future repayment off it while the current
    # column is quoted net overstated the future figure for every offset loan.
    #
    # The offset is held flat at today's total, which is the assumption the
    # caption under this table states.
    def interest_bearing_projected_balance(row_index)
      gross = BigDecimal(projected_rows[row_index][:beginning_balance].to_s)

      [ gross - offset_total, BigDecimal("0") ].max
    end

    # One query for the whole table. The offset is held flat at today's total
    # by construction, so asking per row was a query per row for an answer that
    # cannot change between them (Codacy, #79).
    def offset_total
      @offset_total ||= BigDecimal(loan.offset_accounts.sum(:balance).to_s)
    end

    # From today's actual balance forward -- see the note at the top of this
    # class for why this is not the contracted schedule.
    #
    # Re-amortising, not the default :hold projection the payoff card uses
    # (CodeRabbit, #79). Two reasons, and the second is the serious one:
    #
    #   1. Consistency. This table quotes the RE-AMORTISED repayment at each
    #      change, so the balance those quotes are read off must be the one
    #      that repayment produces. Under :hold the trajectory assumed the
    #      borrower kept paying today's amount through every future change,
    #      so the second and later rows were quoted off a balance that could
    #      not occur.
    #   2. A held repayment stops covering the interest once the rate rises
    #      far enough, the simulation never converges, `applicable?` goes
    #      false and this table renders NOTHING -- precisely the case a
    #      borrower opens it for. On a ~$400k loan at 6.18% the cliff was a
    #      rise to about 7.5%.
    def projection
      @projection ||= Loan::PayoffProjection.new(loan, payment_strategy: :reamortize)
    end

    def projected_rows
      @projected_rows ||= projection.applicable? ? projection.payments : []
    end
end
