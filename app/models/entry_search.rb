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
  attribute :merchants, array: true
  attribute :tags, array: true

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
      # "t") so every provider in PENDING_PROVIDERS is covered. Previously this
      # hardcoded only simplefin/plaid/lunchflow, dropping enable_banking.
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

    def apply_category_filter(scope, categories)
      return scope unless categories.present?

      all_uncategorized_names = Category.all_uncategorized_names
      include_uncategorized = (categories & all_uncategorized_names).any?
      real_categories = categories - all_uncategorized_names
      parent_category_ids = Category.where(name: real_categories).pluck(:id)

      query = scope.joins("LEFT JOIN categories ON categories.id = transactions.category_id")
      uncategorized_condition = "categories.id IS NULL AND transactions.kind NOT IN (?)"

      if parent_category_ids.empty?
        if include_uncategorized
          query.where(
            "categories.name IN (?) OR (#{uncategorized_condition})",
            real_categories.presence || [], Transaction::TRANSFER_KINDS
          )
        else
          query.where(categories: { name: real_categories })
        end
      elsif include_uncategorized
        query.where(
          "categories.name IN (?) OR categories.parent_id IN (?) OR (#{uncategorized_condition})",
          real_categories, parent_category_ids, Transaction::TRANSFER_KINDS
        )
      else
        query.where(
          "categories.name IN (?) OR categories.parent_id IN (?)",
          real_categories, parent_category_ids
        )
      end
    end

    def apply_type_filter(scope, types)
      return scope unless types.present?
      return scope if types.sort == %w[expense income transfer]

      case types.sort
      when [ "transfer" ]
        scope.where(transactions: { kind: Transaction::TRANSFER_KINDS })
      when [ "expense" ]
        scope.where("entries.amount >= 0").where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
      when [ "income" ]
        scope.where("entries.amount < 0").where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
      when [ "expense", "transfer" ]
        scope.where("entries.amount >= 0 OR transactions.kind IN (?)", Transaction::TRANSFER_KINDS)
      when [ "income", "transfer" ]
        scope.where("entries.amount < 0 OR transactions.kind IN (?)", Transaction::TRANSFER_KINDS)
      when [ "expense", "income" ]
        scope.where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
      else
        scope
      end
    end

    def apply_merchant_filter(scope, merchants)
      return scope unless merchants.present?

      scope
        .joins("INNER JOIN merchants ON merchants.id = transactions.merchant_id")
        .where(merchants: { name: merchants })
    end

    def apply_tag_filter(scope, tags)
      return scope unless tags.present?

      scope.where(<<~SQL.squish, tags)
        EXISTS (
          SELECT 1
          FROM taggings
          INNER JOIN tags ON tags.id = taggings.tag_id
          WHERE taggings.taggable_id = transactions.id
            AND taggings.taggable_type = 'Transaction'
            AND tags.name IN (?)
        )
      SQL
    end

    def apply_transaction_join(scope)
      scope.joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
    end
  end

  def build_query(scope)
    query = scope.joins(:account)
    query = self.class.apply_search_filter(query, search)
    query = self.class.apply_date_filters(query, start_date, end_date)
    query = self.class.apply_amount_filter(query, amount, amount_operator)
    query = self.class.apply_accounts_filter(query, accounts, account_ids)

    if transaction_filters_present?
      query = self.class.apply_transaction_join(query)
      query = self.class.apply_category_filter(query, categories)
      query = self.class.apply_type_filter(query, types)
      query = self.class.apply_merchant_filter(query, merchants)
      query = self.class.apply_tag_filter(query, tags)
    end

    query = self.class.apply_status_filter(query, status)
    query
  end

  private
    def transaction_filters_present?
      categories.present? || effective_type_filter_present? || merchants.present? || tags.present?
    end

    def effective_type_filter_present?
      types.present? && types.sort != %w[expense income transfer]
    end
end
