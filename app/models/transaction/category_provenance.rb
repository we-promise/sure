class Transaction::CategoryProvenance
  attr_reader :status, :source, :category_id, :recorded_at

  def self.for(transaction)
    enrichments = transaction.auto_category_enrichments.to_a
    return nil if enrichments.empty?

    # value is the jsonb string of the category UUID (see
    # Family::AutoCategorizer#cached_transaction_ids:
    # `data_enrichments.value = to_jsonb(transactions.category_id::text)`)
    matching = enrichments.find { |e| e.value.to_s == transaction.category_id.to_s }

    # The association is ordered updated_at DESC, so .first is the latest
    # automatic assignment when none matches the current category.
    row = matching || enrichments.first

    new(
      status: matching ? :current : :history,
      source: row.source,
      category_id: row.value.to_s.presence,
      recorded_at: row.updated_at
    )
  end

  def initialize(status:, source:, category_id:, recorded_at:)
    @status = status
    @source = source
    @category_id = category_id
    @recorded_at = recorded_at
  end

  def current?
    status == :current
  end

  def history?
    status == :history
  end
end
