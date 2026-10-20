class Loan
  # What a loan has repaid so far, split into principal and interest.
  #
  # The principal figure comes from the same ledger replay that reduces the
  # balance, so extra payments and prepayments are included. Interest comes from
  # the full payments in that ledger. A linked principal-only transfer carries
  # no interest of its own, so its instalment interest is read from the schedule
  # instead -- it was paid as a separate expense.
  #
  # A loan with no opening anchor has no ledger to replay. It falls back to the
  # recorded balance as of that date for principal and the schedule for interest.
  class PaidBreakdown
    def initialize(loan, as_of: Date.current)
      @loan = loan
      @as_of = as_of
    end

    def principal
      @principal ||= Money.new(totals.fetch(:principal), currency)
    end

    def interest
      @interest ||= Money.new(totals.fetch(:interest), currency)
    end

    def total
      @total ||= Money.new(totals.fetch(:principal) + totals.fetch(:interest), currency)
    end

    def ratios
      @ratios ||= begin
        amount = total.amount

        if amount.positive?
          {
            principal: principal.amount.fdiv(amount),
            interest: interest.amount.fdiv(amount)
          }
        else
          { principal: 0.0, interest: 0.0 }
        end
      end
    end

    private
      attr_reader :loan, :as_of

      def totals
        @totals ||= begin
          if (payments = principal_payments)
            changes = payments.changes.select { |date, _change| date <= as_of }
            principal = changes.sum(BigDecimal("0")) { |_date, change| change.principal_paid }
            interest = changes.sum(BigDecimal("0")) { |_date, change| change.interest_paid }
            interest += linked_interest(changes)

            { principal: principal, interest: interest }
          else
            {
              principal: balance_principal_paid(as_of),
              interest: scheduled_totals.fetch(:interest)
            }
          end
        end
      end

      def principal_payments
        return nil unless loan.account && loan.amortizable?

        Loan::PrincipalPayments.for(
          loan,
          entries: Balance::SyncCache.new(loan.account).entries
        )
      end

      # Linked principal-only transfers are recorded at their principal amount.
      # When one matches a scheduled instalment's principal, the interest for
      # that instalment was paid separately and belongs in the total. Matching
      # on the amount keeps prepayments out of this: they have no instalment
      # interest.
      def linked_interest(changes)
        counted = Set.new
        covered = changes.each_with_object(Set.new) do |(date, change), instalments|
          next unless change.interest_paid.positive?

          payment = schedule.payment_for(date)
          instalments << payment.number if payment
        end

        changes.sum(BigDecimal("0")) do |date, change|
          next BigDecimal("0") unless change.linked_paid.positive?

          payment = schedule.payment_for(date)
          next BigDecimal("0") if payment.nil? || counted.include?(payment.number) || covered.include?(payment.number)
          next BigDecimal("0") unless same_amount?(change.linked_paid, payment.principal.amount)

          counted << payment.number
          payment.interest.amount
        end
      end

      def scheduled_totals
        @scheduled_totals ||= begin
          paid = schedule.payments.select { |payment| payment.date <= as_of }

          {
            principal: paid.sum(BigDecimal("0")) { |payment| payment.principal.amount },
            interest: paid.sum(BigDecimal("0")) { |payment| payment.interest.amount }
          }
        end
      end

      def balance_principal_paid(as_of)
        borrowed = loan.original_balance.amount
        account = loan.account
        return BigDecimal("0") unless borrowed.positive? && account

        snapshot_date, balance = account.balances
          .where(currency: account.currency, date: ..as_of)
          .order(date: :desc)
          .pick(:date, :balance)

        if as_of == Date.current && account.has_current_anchor? &&
            (snapshot_date.nil? || account.current_anchor_date > snapshot_date)
          balance = account.current_anchor_balance
        end

        return BigDecimal("0") unless balance

        (borrowed - balance.to_d.abs).clamp(BigDecimal("0"), borrowed)
      end

      def same_amount?(left, right)
        (left - right).abs <= BigDecimal("1") / (10 ** currency_precision)
      end

      def schedule
        @schedule ||= loan.amortization_schedule
      end

      def currency
        loan.account.currency
      end

      def currency_precision
        @currency_precision ||= Money::Currency.new(currency).default_precision || 2
      end
  end
end
