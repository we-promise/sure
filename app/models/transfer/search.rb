# Filters a Transfer or RejectedTransfer relation: both pair an inflow and an
# outflow transaction, and the account and date filters match either leg.
class Transfer::Search
  include ScopedSearch

  attribute :status, :string
  attribute :account_id, :string
  attribute :start_date, :date
  attribute :end_date, :date

  def transfers_scope
    relation = scope
    relation = relation.where(status:) unless status.nil?
    relation = with_either_leg_in(relation, leg_entries.where(account_id:)) unless account_id.nil?
    relation = with_either_leg_in(relation, dated_leg_entries) unless start_date.nil? && end_date.nil?
    relation
  end

  private

    def dated_leg_entries
      within_range(leg_entries, :date, start_date, end_date)
    end

    def leg_entries
      Entry.where(entryable_type: "Transaction")
    end

    def with_either_leg_in(relation, entries)
      transaction_ids = entries.select(:entryable_id)
      relation.where(inflow_transaction_id: transaction_ids).or(relation.where(outflow_transaction_id: transaction_ids))
    end
end
