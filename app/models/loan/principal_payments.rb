class Loan
  # Replays a loan's entries so a full payment reduces principal by only the
  # amount left after interest. Linked principal-only transfers and prepayments
  # still reduce principal by the full amount.
  class PrincipalPayments
    Change = Data.define(:principal_paid, :principal_added, :interest_paid, :linked_paid) do
      def net
        principal_added - principal_paid
      end
    end

    def self.for(loan, entries:)
      account = loan&.account
      return nil unless loan&.amortizable? && account&.has_opening_anchor?
      return nil unless account.opening_anchor_balance.positive?

      new(loan, entries: entries)
    end

    def initialize(loan, entries:)
      @loan = loan
      @account = loan.account
      @entries = entries
      @changes = build_changes
    end

    def change_for(date)
      @changes[date]
    end

    def changes
      @changes
    end

    private
      attr_reader :loan, :account, :entries

      def build_changes
        changes = {}
        principal = account.opening_anchor_balance.to_d.round(precision)
        last_date = account.opening_anchor_date

        entries.group_by(&:date).sort_by(&:first).each do |date, date_entries|
          next if date < last_date

          if (valuation = date_entries.find(&:valuation?))
            principal = valuation.amount.to_d.round(precision)
            last_date = date
            changes[date] = zero_change
            next
          end

          transactions = date_entries.select(&:transaction?)
          next if transactions.empty?

          linked, unlinked = transactions.partition { |entry| linked?(entry) }
          interest = accrued_interest(principal, last_date, date)

          linked_positive = linked.select { |entry| entry.amount.positive? }
          linked_negative = linked.select { |entry| entry.amount.negative? }
          linked_full, linked_principal_only = linked_negative.partition { |entry| linked_full_payment?(entry) }

          linked_added = linked_positive.sum(BigDecimal("0"), &:amount).round(precision)
          linked_principal_paid = -linked_principal_only.sum(BigDecimal("0"), &:amount).round(precision)
          linked_full_payment = -linked_full.sum(BigDecimal("0"), &:amount).round(precision)

          principal += linked_added
          linked_principal_paid = [ linked_principal_paid, principal ].min
          principal -= linked_principal_paid

          unlinked_added = unlinked.select { |entry| entry.amount.positive? }.sum(BigDecimal("0"), &:amount).round(precision)
          unlinked_payment = -unlinked.select { |entry| entry.amount.negative? }.sum(BigDecimal("0"), &:amount).round(precision)
          full_payment = linked_full_payment + unlinked_payment

          principal += unlinked_added
          full_paid = [ (full_payment - interest).round(precision), BigDecimal("0") ].max
          full_paid = [ full_paid, principal ].min
          principal -= full_paid

          changes[date] = Change.new(
            principal_paid: linked_principal_paid + full_paid,
            principal_added: linked_added + unlinked_added,
            interest_paid: [ interest, full_payment ].min,
            linked_paid: linked_principal_paid
          )
          last_date = date
        end

        changes
      end

      def accrued_interest(principal, from_date, to_date)
        return BigDecimal("0") if principal <= 0 || to_date <= from_date

        total = (from_date...to_date).sum(BigDecimal("0")) do |date|
          principal * rate_resolver.accrual_rate_for(date) / 100 / 365
        end

        total.round(precision)
      end

      def linked?(entry)
        linked_transaction_ids.include?(entry.entryable_id)
      end

      # A linked transfer is principal-only by default: the app records the
      # principal there and the interest as a separate expense. An external bank
      # transfer matching the scheduled EMI is a full payment and must be split;
      # otherwise its whole amount would repay principal.
      def linked_full_payment?(entry)
        return false unless entry.amount.negative?

        payment = scheduled_payment_for(entry.date)
        return false if payment.nil?

        amount = -entry.amount
        payment_amount = payment.payment.amount
        principal_amount = payment.principal.amount

        amount <= payment_amount * BigDecimal("1.02") &&
          amount > principal_amount &&
          (amount - payment_amount).abs < (amount - principal_amount).abs
      end

      def scheduled_payment_for(date)
        @schedule ||= loan.amortization_schedule
        @schedule&.payment_for(date)
      end

      def linked_transaction_ids
        @linked_transaction_ids ||= begin
          ids = entries.select(&:transaction?).map(&:entryable_id)
          if ids.empty?
            Set.new
          else
            Transfer.where("inflow_transaction_id IN (?) OR outflow_transaction_id IN (?)", ids, ids)
              .pluck(:inflow_transaction_id, :outflow_transaction_id)
              .flatten
              .to_set
          end
        end
      end

      def rate_resolver
        @rate_resolver ||= Loan::RateResolver.for(loan)
      end

      def precision
        @precision ||= Money::Currency.new(account.currency).default_precision || 2
      end

      def zero_change
        Change.new(
          principal_paid: BigDecimal("0"),
          principal_added: BigDecimal("0"),
          interest_paid: BigDecimal("0"),
          linked_paid: BigDecimal("0")
        )
      end
  end
end
