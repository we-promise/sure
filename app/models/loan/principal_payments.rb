class Loan
  # Replays a loan's entries so unlinked payments reduce principal by only the
  # amount left after interest, as a reducing-balance loan does.
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

          linked_added = linked.select { |entry| entry.amount.positive? }.sum(BigDecimal("0"), &:amount).round(precision)
          linked_paid = -linked.select { |entry| entry.amount.negative? }.sum(BigDecimal("0"), &:amount).round(precision)
          principal += linked_added
          linked_paid = [ linked_paid, principal ].min
          principal -= linked_paid

          unlinked_added = unlinked.select { |entry| entry.amount.positive? }.sum(BigDecimal("0"), &:amount).round(precision)
          unlinked_payment = -unlinked.select { |entry| entry.amount.negative? }.sum(BigDecimal("0"), &:amount).round(precision)
          principal += unlinked_added
          unlinked_paid = [ (unlinked_payment - interest).round(precision), BigDecimal("0") ].max
          unlinked_paid = [ unlinked_paid, principal ].min
          principal -= unlinked_paid

          changes[date] = Change.new(
            principal_paid: linked_paid + unlinked_paid,
            principal_added: linked_added + unlinked_added,
            interest_paid: [ interest, unlinked_payment ].min,
            linked_paid: linked_paid
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
