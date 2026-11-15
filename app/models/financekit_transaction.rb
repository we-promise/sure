class FinancekitTransaction < ApplicationRecord
  belongs_to :financekit_account_lineage
  belongs_to :financekit_account, optional: true
  belongs_to :entry, optional: true
  has_many :financekit_conflicts, dependent: :nullify

  # One definition of the rule every caller shares: a record is under review
  # while any conflict about it is still open, whatever created or closed the
  # last one. Not memoized per pass — an importer creates conflicts for the same
  # identity while it works, and a cached answer would clear a review that had
  # just been raised. The financekit_transaction_id index makes each check an
  # index-only existence probe.
  def review_required_from_conflicts
    financekit_conflicts.open.exists?
  end

  # For callers that are done writing. Mid-write callers assign
  # review_required_from_conflicts and save it with the rest of the record.
  def refresh_review_required!
    update!(review_required: review_required_from_conflicts)
  end
end
