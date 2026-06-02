# A virtual envelope tracks an earmarked balance derived *entirely* from
# transactions — a fixed monthly contribution credited each month, less the
# money spent against its category. It has no link to a physical account
# balance (account-agnostic): Sure tracks the allocation, not the location, so
# many envelopes can share a single pooled account (e.g. one cash ISA).
#
# Two modes share one model and identical balance mechanics:
#   - Sinking fund   → no target, runs indefinitely (holidays, gifts, clothing)
#   - Virtual goal   → optional target (+ optional deadline); "reached" when
#                      balance >= target (boiler, car fund)
# The only difference is whether a target/deadline is displayed.
#
# Complements account-linked Goals (#1798): an envelope is the
# transaction-derived balance mode, a Goal is the account-linked balance mode.
# The two coexist.
class Envelope < ApplicationRecord
  include Monetizable

  COLORS = Category::COLORS
  ICONS = Category.icon_codes

  belongs_to :family
  # The category whose transactions debit this envelope. Optional so an
  # envelope can exist before a category is wired up (it simply has no spend
  # until one is set). Unique per category at the DB level.
  belongs_to :category, optional: true

  validates :name, presence: true, length: { maximum: 255 }
  validates :monthly_contribution, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true
  validates :starts_on, presence: true
  validates :target_amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }, allow_nil: true
  validates :icon, inclusion: { in: ICONS, allow_nil: true }
  validate :category_must_belong_to_family
  validate :category_must_be_unused
  validate :target_date_requires_target_amount

  monetize :monthly_contribution, :target_amount, :total_contributed, :total_spent,
           :current_balance, :remaining_amount

  scope :alphabetically, -> { order(Arel.sql("LOWER(name) ASC")) }

  # --- Balance mechanics (transaction-derived, account-agnostic) ---

  # Number of monthly contributions that have accrued. The contribution for
  # the start month lands immediately (so a fresh envelope isn't stuck at
  # £0), hence the +1: start month → 1, next month → 2, and so on.
  def months_elapsed
    return 0 if starts_on.nil? || starts_on > Date.current

    (Date.current.year - starts_on.year) * 12 + (Date.current.month - starts_on.month) + 1
  end

  # Total credited to the envelope to date: the monthly amount times the
  # number of months elapsed. Accumulates indefinitely — never resets.
  def total_contributed
    monthly_contribution.to_d * months_elapsed
  end

  # Net spend categorised to this envelope's category (and its
  # subcategories) since it started accruing. Sure stores expenses as
  # positive amounts and income/refunds as negative, so summing entries.amount
  # nets refunds back into the envelope. Amounts are converted to the
  # envelope's currency via the daily exchange rate, falling back to 1:1 when
  # no rate row exists (e.g. same-currency transactions). Pending and
  # user-excluded entries are ignored, matching budget semantics.
  def total_spent
    return 0.to_d if category_id.nil? || starts_on.nil?

    @total_spent ||= Entry
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .joins("LEFT JOIN exchange_rates er ON er.date = entries.date AND er.from_currency = entries.currency AND er.to_currency = #{self.class.connection.quote(currency)}")
      .where(account_id: family.accounts.visible.select(:id))
      .where(transactions: { category_id: spend_category_ids })
      .where(excluded: false)
      .where("entries.date >= ?", starts_on)
      .merge(Transaction.excluding_pending)
      .sum("entries.amount * COALESCE(er.rate, 1)")
      .to_d
  end

  # The running available balance. May go negative when spend outpaces
  # contributions — spending is never blocked; future contributions
  # replenish it.
  def current_balance
    total_contributed - total_spent
  end

  def negative?
    current_balance.negative?
  end

  # Virtual-goal mode (a target is set) vs sinking-fund mode (no target).
  def has_target?
    target_amount.present?
  end

  def sinking_fund?
    !has_target?
  end

  def reached?
    has_target? && current_balance >= target_amount.to_d
  end

  # Amount still needed to hit the target (goal mode only). Nil for sinking
  # funds; clamped at zero so an over-funded envelope reports 0, not negative.
  def remaining_amount
    return nil unless has_target?

    [ target_amount.to_d - current_balance, 0 ].max
  end

  def progress_percent
    return nil unless has_target?
    return 0 if target_amount.to_d.zero?

    [ [ (current_balance.to_d / target_amount.to_d * 100).round, 0 ].max, 100 ].min
  end

  # Months to reach the target at the current monthly contribution. Nil when
  # there's no target or no contribution (can't project), 0 when already met.
  def months_to_target
    return nil unless has_target? && monthly_contribution.to_d.positive?
    return 0 if remaining_amount.to_d.zero?

    (remaining_amount.to_d / monthly_contribution.to_d).ceil
  end

  # Drives the status pill / warning indicator.
  #   :negative → overspent (balance below zero); show a warning
  #   :reached  → goal mode and target met
  #   :on_track → goal mode, funded, not yet reached
  #   :tracking → sinking fund (no target), funded
  def status
    return :negative if negative?
    return :reached if reached?

    has_target? ? :on_track : :tracking
  end

  # Recent spend/refund entries categorised to this envelope, newest first.
  # Used on the show page to explain the balance.
  def recent_entries(limit: 10)
    return Entry.none if category_id.nil?

    family.entries
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(account_id: family.accounts.visible.select(:id))
          .where(transactions: { category_id: spend_category_ids })
          .where(excluded: false)
          .where("entries.date >= ?", starts_on)
          .order(date: :desc, created_at: :desc)
          .limit(limit)
  end

  private
    # The envelope's category plus any of its subcategories, so spend logged
    # against a child category (e.g. "Flights" under "Holidays") still debits
    # the envelope — matching how budget parent categories roll up.
    def spend_category_ids
      return [] if category.nil?

      [ category.id ] + category.subcategories.pluck(:id)
    end

    def category_must_belong_to_family
      return if category.nil? || family.nil?
      return if category.family_id == family_id

      errors.add(:category, :must_belong_to_family)
    end

    # Belt-and-suspenders for the partial-unique DB index: one category can
    # back at most one envelope, otherwise its spend would be double-counted.
    def category_must_be_unused
      return if category_id.nil?

      clashing = Envelope.where(category_id: category_id).where.not(id: id)
      errors.add(:category, :already_taken) if clashing.exists?
    end

    def target_date_requires_target_amount
      return if target_date.blank? || target_amount.present?

      errors.add(:target_date, :requires_target_amount)
    end
end
