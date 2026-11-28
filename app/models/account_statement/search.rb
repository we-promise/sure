class AccountStatement::Search
  include ScopedSearch

  attribute :account_id, :string
  attribute :review_status, :string
  attribute :content_sha256, :string
  attribute :start_date, :date
  attribute :end_date, :date

  # Dates select statements whose period overlaps the range.
  def account_statements_scope
    relation = scope
    relation = relation.where(account_id:) unless account_id.nil?
    relation = relation.where(review_status:) unless review_status.nil?
    # The column only holds lowercase hex.
    relation = relation.where(content_sha256: content_sha256.downcase) unless content_sha256.nil?
    relation = relation.where(period_end_on: start_date..) unless start_date.nil?
    relation = relation.where(period_start_on: ..end_date) unless end_date.nil?
    relation
  end
end
