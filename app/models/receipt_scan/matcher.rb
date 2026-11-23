# Looks for the bank's version of a receipt's payment on the account the user picked, for the
# case where bank data arrived before the photo. A pending bank entry counts: the provider later
# books that same entry, so attaching the receipt to it avoids a second expense. Name is deliberately ignored: receipt merchant
# names and bank descriptions rarely agree.
class ReceiptScan::Matcher
  Result = Data.define(:kind, :entries)

  TRANSACTIONS_JOIN = "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'".freeze

  def initialize(scan, extraction)
    @scan = scan
    @extraction = extraction
  end

  # kind is :skip (this receipt is never matched), :none, :single, :ambiguous or
  # :duplicate_receipt (another receipt on the account already records this payment)
  def result
    earlier_receipt = earlier_receipt_entry
    return Result.new(kind: :duplicate_receipt, entries: [ earlier_receipt ]) if earlier_receipt
    return Result.new(kind: :skip, entries: []) if skip?

    candidates = bank_candidates.to_a
    kind = case candidates.size
    when 0 then :none
    when 1 then :single
    else :ambiguous
    end
    Result.new(kind:, entries: candidates)
  end

  private
    attr_reader :scan, :extraction

    def skip?
      extraction.document_kind != "receipt" ||
        extraction.payment_method == "cash" ||
        extraction.currency != scan.account.currency ||
        extraction.total.nil? || !extraction.total.positive? ||
        extraction.date.nil?
    end

    def same_payment
      scope = scan.account.entries
        .joins(TRANSACTIONS_JOIN)
        .where(amount: extraction.total, currency: extraction.currency, parent_entry_id: nil)
      placeholder_entry_id = scan.linked_transaction&.entry&.id
      placeholder_entry_id ? scope.where.not(id: placeholder_entry_id) : scope
    end

    # Another receipt on this account for the same amount and receipt date. Compared on the date
    # read from that receipt, since a receipt merged into or claimed by a bank entry carries the
    # bank's posting date.
    RECEIPT_DATE_SQL = <<~SQL.squish.freeze
      CASE WHEN transactions.extra -> 'receipt' ->> 'date' ~ '^\\d{4}-\\d{2}-\\d{2}$'
        THEN (transactions.extra -> 'receipt' ->> 'date')::date
        ELSE entries.date
      END
    SQL

    def earlier_receipt_entry
      return if extraction.total.nil? || extraction.date.nil? || extraction.currency.blank?

      same_payment
        .where("transactions.extra ? 'receipt'")
        .where("#{RECEIPT_DATE_SQL} = ?", extraction.date)
        .order(:created_at)
        .first
    end

    def bank_candidates
      window = ReceiptScan::MATCH_DATE_WINDOW.days

      same_payment
        .where(date: (extraction.date - window)..(extraction.date + window))
        .where.not("transactions.extra ? 'receipt'")
        # Transfers and card payments move money, they don't buy anything.
        .where("transactions.kind IS NULL OR transactions.kind NOT IN (?)", Transaction::TRANSFER_KINDS)
        .where.not(id: Entry.where.not(parent_entry_id: nil).select(:parent_entry_id))
        .where(excluded: false)
        .order(:date, :created_at)
    end
end
