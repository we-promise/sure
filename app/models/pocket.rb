class Pocket < ApplicationRecord
  include Monetizable

  belongs_to :account
  belongs_to :tag, optional: true

  enum :fill_direction, { inflows: "inflows", outflows: "outflows", both: "both" }, default: :inflows

  validates :name, :currency, presence: true
  validate :account_must_be_depository
  validates :allocated_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :tag_id, uniqueness: { scope: :account_id, allow_nil: true }
  validate :total_pockets_within_account_balance
  validate :tag_belongs_to_same_family

  after_save :sync_from_tag, if: -> { saved_change_to_tag_id? || saved_change_to_fill_direction? }

  PALETTE = %w[#875BF7 #6471EB #4DA568 #E99537 #DB5A54 #DF4E92 #61C9EA #805DEE].freeze
  COLORS = Category::COLORS
  ICONS = Category.icon_codes

  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }, allow_blank: true
  validates :icon, inclusion: { in: -> { Category.icon_codes }, allow_nil: true }

  monetize :allocated_amount

  def display_color
    color.presence || tag&.color.presence || PALETTE[id.bytes.sum % PALETTE.size]
  end

  def display_icon
    icon.presence || "wallet"
  end

  def allocation_percent(balance)
    return 0 if balance.nil? || balance <= 0

    [ (allocated_amount / balance.to_f * 100).round, 100 ].min
  end

  def recompute_from_tag!
    return unless tag_id.present?
    update_column(:allocated_amount, tagged_transaction_total(tag_id))
  end

  # Full recompute (via recompute_from_tag!) rather than an incremental adjust_by:
  # incrementally adding/subtracting per-tagging deltas can diverge from the aggregate
  # for fill_direction "both" (each step clamps at 0, whereas the aggregate only floors
  # the net total at 0 — order of tagging/untagging can then produce different results).
  # recompute_from_tag! uses update_column, same as increment!/decrement! did, so it
  # still skips AR callbacks/validations and avoids re-triggering the Tagging callbacks
  # that called these methods.
  def apply_tagging(tagging)
    delta = tagging_transaction_delta(tagging)
    return unless delta

    recompute_from_tag!
  end

  # Must run after the Tagging row is actually deleted (see Tagging#unfill_linked_pocket,
  # registered as after_destroy) so the aggregate query in recompute_from_tag! excludes it.
  def reverse_tagging(tagging)
    delta = tagging_transaction_delta(tagging)
    return unless delta

    recompute_from_tag!
  end

  private

    def sync_from_tag
      _, new_tag_id = saved_change_to_tag_id || [ nil, tag_id ]

      # Full recompute: replace current amount with the fresh sum from DB
      new_amount = new_tag_id.present? ? tagged_transaction_total(new_tag_id) : 0
      update_column(:allocated_amount, new_amount)
    end

    def direction_condition
      case fill_direction
      when "inflows"  then "entries.amount < 0"
      when "outflows" then "entries.amount > 0"
      else nil
      end
    end

    def tagged_transaction_total(tag_id)
      # Runs its own independent aggregate query, so it must not inherit an
      # ambient current_scope (e.g. Entry.bulk_update! invoked via a
      # `family.entries` has_many :through relation leaves an accounts JOIN
      # in scope). Entry.from(subq, ...) replaces the FROM clause, so any
      # inherited JOIN referencing "entries" would break the query.
      Entry.unscoped do
        subq = Entry.joins(
          "INNER JOIN transactions ON transactions.id = entries.entryable_id
             AND entries.entryable_type = 'Transaction'"
        ).joins(
          "INNER JOIN taggings ON taggings.taggable_id = transactions.id
             AND taggings.taggable_type = 'Transaction'"
        ).where(entries: { account_id: account_id, currency: currency })
         .where(taggings: { tag_id: tag_id })
         .select("DISTINCT entries.id, entries.amount")

        if fill_direction == "both"
          # Net = incomes - expenses, floored at 0.
          # DB convention: income = negative amount, expense = positive → SUM(-amount) gives net.
          Entry.from(subq, :deduplicated_entries)
               .pick(Arel.sql("GREATEST(0, COALESCE(SUM(-amount), 0))"))
               .to_d
        else
          subq = subq.where(direction_condition)
          Entry.from(subq, :deduplicated_entries)
               .pick(Arel.sql("COALESCE(SUM(ABS(amount)), 0)"))
               .to_d
        end
      end
    end

    # Returns a signed delta: positive = add to pocket, negative = subtract from pocket.
    def tagging_transaction_delta(tagging)
      return nil unless tagging.taggable_type == "Transaction"

      entry = tagging.taggable.entry
      return nil unless entry
      return nil unless entry.currency == currency

      amount = entry.amount
      return nil unless amount

      case fill_direction
      when "inflows"  then amount < 0 ? amount.abs : nil  # income only, always positive
      when "outflows" then amount > 0 ? amount : nil      # expense only, always positive
      else -amount  # income (neg in DB) → positive delta; expense (pos in DB) → negative delta
      end
    end

    def total_pockets_within_account_balance
      return unless account && allocated_amount

      sibling_total = account.pockets.where.not(id: id).sum(:allocated_amount)
      if sibling_total + allocated_amount > account.balance
        errors.add(:allocated_amount, :exceeds_account_balance,
          available: account.balance - sibling_total,
          currency: account.currency)
      end
    end

    def account_must_be_depository
      return unless account

      errors.add(:account, :not_depository) unless account.depository?
    end

    def tag_belongs_to_same_family
      return unless tag && account

      unless tag.family_id == account.family_id
        errors.add(:tag, :wrong_family)
      end
    end
end
