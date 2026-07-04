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

  # increment!/decrement! are intentional here: they skip AR callbacks and validations
  # (including total_pockets_within_account_balance) to avoid re-triggering the Tagging
  # callbacks that called these methods. This means allocated_amount can temporarily exceed
  # the account balance under concurrent tagging — pockets_overflow? surfaces that to the user.
  # The DB check constraint (chk_pockets_allocated_amount_non_negative) remains the hard floor.
  def apply_tagging(tagging)
    delta = tagging_transaction_delta(tagging)
    return unless delta

    adjust_by(delta)
  end

  def reverse_tagging(tagging)
    delta = tagging_transaction_delta(tagging)
    return unless delta

    adjust_by(-delta)
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
        ApplicationRecord.connection.select_value(
          "SELECT GREATEST(0, COALESCE(SUM(-amount), 0)) FROM (#{subq.to_sql}) deduplicated_entries"
        ).to_d
      else
        subq = subq.where(direction_condition)
        ApplicationRecord.connection.select_value(
          "SELECT COALESCE(SUM(ABS(amount)), 0) FROM (#{subq.to_sql}) deduplicated_entries"
        ).to_d
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

    def adjust_by(delta)
      if delta >= 0
        increment!(:allocated_amount, delta)
      else
        decrement!(:allocated_amount, [ delta.abs, allocated_amount ].min)
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
