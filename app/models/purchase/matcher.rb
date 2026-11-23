# Finds the bank transaction that paid for a purchase: same amount and currency, dated from the
# order date to a few days later, on an account the purchase's user may change.
class Purchase::Matcher
  Result = Data.define(:kind, :entries)

  TRANSACTIONS_JOIN = "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'".freeze
  # Review reasons that make the extracted amount or date unreliable for matching.
  BLOCKING_REASONS = %w[missing_total missing_date non_positive_total unknown_currency].freeze

  def initialize(purchase)
    @purchase = purchase
  end

  # @return [Result] kind :single, :ambiguous, :none, or :skipped (never matched automatically)
  def result
    return Result.new(kind: :skipped, entries: []) if skip?

    entries = candidates.to_a
    kind = case entries.size
    when 0 then :none
    when 1 then :single
    else :ambiguous
    end
    Result.new(kind:, entries:)
  end

  private
    attr_reader :purchase

    # Cash and instalment purchases have no single bank payment of their total to find.
    def skip?
      purchase.paid_by_installments? || purchase.paid_by_cash? ||
        purchase.total.nil? || !purchase.total.positive? ||
        purchase.ordered_on.nil? || purchase.currency.blank? ||
        (purchase.review_reasons.map { _1["reason"] } & BLOCKING_REASONS).any?
    end

    def candidates
      Entry
        .joins(TRANSACTIONS_JOIN)
        .where(account_id: Account.annotatable_by(purchase.user).where(family_id: purchase.family_id).select(:id))
        .where(amount: purchase.total, currency: purchase.currency, parent_entry_id: nil)
        # A transaction the user excluded isn't a payment; a split parent is excluded by design.
        .where("entries.excluded = FALSE OR EXISTS (SELECT 1 FROM entries parts WHERE parts.parent_entry_id = entries.id)")
        .where(date: purchase.ordered_on..(purchase.ordered_on + purchase.match_window_days))
        .where(Transaction.not_pending_sql)
        .where("transactions.kind IS NULL OR transactions.kind NOT IN (?)", Transaction::TRANSFER_KINDS)
        .where("transactions.extra -> 'receipt' ->> 'status' IS DISTINCT FROM 'processing'")
        .where.not(entryable_id: Purchase.where.not(transaction_id: nil).where.not(id: purchase.id).select(:transaction_id))
        .where.not(id: purchase.rejected_entry_ids)
        .order(:date, :created_at)
    end
end
