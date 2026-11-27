class Loan
  # What a loan has repaid so far, split into principal and interest.
  #
  # The figures come from the same ledger replay that reduces the balance, so
  # a linked payment, an extra payment and a separate interest line are all
  # reflected. A loan without a replay (no schedule, no usable opening anchor)
  # falls back to its recorded balance for principal and the contracted
  # schedule for interest.
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

    # True when the ledger replay does not apply, so interest comes from the
    # contracted schedule. That figure is the amount due, not the amount paid.
    def estimated_interest?
      principal_payments.nil?
    end

    # True when the replay dropped entries it could not convert into the
    # account's currency, so the totals understate what was paid. The balance
    # calculation drops the same entries, keeping the two figures consistent.
    def incomplete?
      principal_payments
      @incomplete == true
    end

    private
      attr_reader :loan, :as_of

      def totals
        @totals ||= if (payments = principal_payments)
          changes = payments.changes.select { |date, _change| date <= as_of }

          {
            principal: changes.sum(BigDecimal("0")) { |_date, change| change.principal_paid },
            interest: changes.sum(BigDecimal("0")) { |_date, change| change.interest_paid }
          }
        else
          {
            principal: balance_principal_paid(as_of),
            interest: scheduled_interest(as_of)
          }
        end
      end

      def principal_payments
        return @principal_payments if defined?(@principal_payments)
        return @principal_payments = nil unless loan.account

        # This replay runs while the page renders. Suppress missing-rate
        # diagnostics here; the next sync will inspect the same data.
        sync_cache = Balance::SyncCache.new(loan.account, report_missing_rates: false)
        entries = sync_cache.entries
        payments = Loan::PrincipalPayments.for(loan, entries: entries)

        # Entries without a rate are dropped from the replay, exactly as the
        # balance calculation drops them. Record that so the card can say the
        # totals are incomplete rather than present them as final.
        @incomplete = payments.present? && sync_cache.unconvertible_entry_count.positive?
        @principal_payments = payments
      end

      # The latest recorded balance on or before `as_of`. Today may not be
      # materialized yet, so a current anchor on or before the date wins when
      # it is newer than the persisted row.
      def balance_principal_paid(as_of)
        borrowed = loan.original_balance.amount
        account = loan.account
        return BigDecimal("0") unless borrowed.positive? && account

        snapshot_date, balance = account.balances
          .where(currency: account.currency, date: ..as_of)
          .order(date: :desc)
          .pick(:date, :balance)

        if account.has_current_anchor? &&
            account.current_anchor_date <= as_of &&
            (snapshot_date.nil? || account.current_anchor_date > snapshot_date)
          balance = account.current_anchor_balance
        end

        return BigDecimal("0") unless balance

        (borrowed - balance.to_d.abs).clamp(BigDecimal("0"), borrowed)
      end

      def scheduled_interest(as_of)
        schedule.payments
          .select { |payment| payment.date <= as_of }
          .sum(BigDecimal("0")) { |payment| payment.interest.amount }
      end

      def schedule
        @schedule ||= loan.amortization_schedule
      end

      def currency
        loan.account.currency
      end
  end
end
