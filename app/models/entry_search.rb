class EntrySearch
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :search, :string
  attribute :amount, :string
  attribute :amount_operator, :string
  attribute :types, array: true
  attribute :status, array: true
  attribute :accounts, array: true
  attribute :account_ids, array: true
  attribute :start_date, :string
  attribute :end_date, :string
  attribute :categories, array: true
  attribute :tags, array: true
  attribute :merchants, array: true

  attr_reader :family

  # `family` is only required to scope the category-name lookup in
  # Transaction::Search.apply_category_filter (see #1480); every other filter
  # here works without it.
  def initialize(filters = {}, family: nil)
    @family = family
    super(filters)
  end

  class << self
    def apply_search_filter(scope, search)
      return scope if search.blank?

      query = scope
      query = query.where("entries.name ILIKE :search OR entries.notes ILIKE :search",
        search: "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
      )
      query
    end

    def apply_date_filters(scope, start_date, end_date)
      return scope if start_date.blank? && end_date.blank?

      query = scope
      query = query.where("entries.date >= ?", start_date) if start_date.present?
      query = query.where("entries.date <= ?", end_date) if end_date.present?
      query
    end

    def apply_amount_filter(scope, amount, amount_operator)
      return scope if amount.blank? || amount_operator.blank?

      query = scope

      case amount_operator
      when "equal"
        query = query.where("ABS(ABS(entries.amount) - ?) <= 0.01", amount.to_f.abs)
      when "less"
        query = query.where("ABS(entries.amount) < ?", amount.to_f.abs)
      when "greater"
        query = query.where("ABS(entries.amount) > ?", amount.to_f.abs)
      end

      query
    end

    def apply_accounts_filter(scope, accounts, account_ids)
      return scope if accounts.blank? && account_ids.blank?

      query = scope
      query = query.where(accounts: { name: accounts }) if accounts.present?
      query = query.where(accounts: { id: account_ids }) if account_ids.present?
      query
    end

    def apply_status_filter(scope, statuses)
      return scope unless statuses.present?
      return scope if statuses.uniq.sort == %w[confirmed pending] # Both selected = no filter

      # Source the pending check from Transaction::PENDING_CHECK_SQL (aliased to
      # "t") so every supported provider is covered.
      pending_condition = <<~SQL.squish
        entries.entryable_type = 'Transaction'
        AND EXISTS (
          SELECT 1 FROM transactions t
          WHERE t.id = entries.entryable_id
          AND (#{Transaction::PENDING_CHECK_SQL})
        )
      SQL

      confirmed_condition = <<~SQL.squish
        entries.entryable_type != 'Transaction'
        OR NOT EXISTS (
          SELECT 1 FROM transactions t
          WHERE t.id = entries.entryable_id
          AND (#{Transaction::PENDING_CHECK_SQL})
        )
      SQL

      case statuses.sort
      when [ "pending" ]
        scope.where(pending_condition)
      when [ "confirmed" ]
        scope.where(confirmed_condition)
      else
        scope
      end
    end
  end

  def build_query(scope)
    query = scope.joins(:account)
    query = self.class.apply_search_filter(query, search)
    query = self.class.apply_date_filters(query, start_date, end_date)
    query = self.class.apply_amount_filter(query, amount, amount_operator)
    query = self.class.apply_accounts_filter(query, accounts, account_ids)
    query = self.class.apply_status_filter(query, status)

    if transaction_specific_filters?
      # Only Transaction entries have a category/merchant/type/tags, so this
      # join is skipped unless one of those filters is active. Most of
      # Transaction::Search's apply_* methods exclude non-Transaction entries
      # as a side effect of their own conditions, but apply_type_filter
      # doesn't when every type is selected (it's a no-op then) — so exclude
      # non-Transaction entries explicitly here instead of relying on that.
      query = query.joins("LEFT JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      query = query.where(entries: { entryable_type: "Transaction" })
      query = Transaction::Search.apply_category_filter(query, categories, family)
      query = Transaction::Search.apply_type_filter(query, types)
      query = Transaction::Search.apply_merchant_filter(query, merchants)
      query = Transaction::Search.apply_tag_filter(query, tags)
    end

    query
  end

  private
    def transaction_specific_filters?
      categories.present? || types.present? || merchants.present? || tags.present?
    end
end
