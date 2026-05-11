class Goal < ApplicationRecord
  include AASM, Monetizable

  COLORS = Category::COLORS

  # Virtual attributes used by the create-modal stepper to capture an
  # optional initial contribution alongside the goal create payload.
  attr_accessor :initial_contribution_amount, :initial_contribution_account_id

  belongs_to :family
  has_many :goal_accounts, dependent: :destroy
  has_many :linked_accounts, through: :goal_accounts, source: :account
  has_many :goal_contributions, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :target_amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validate :must_have_at_least_one_linked_account
  validate :linked_accounts_must_be_depository
  validate :linked_accounts_must_match_goal_currency
  validate :linked_accounts_must_belong_to_family
  validate :currency_locked_once_contributions_exist

  monetize :target_amount

  scope :alphabetically, -> { order(Arel.sql("LOWER(name) ASC")) }
  scope :active_first, lambda {
    order(Arel.sql("CASE state WHEN 'active' THEN 0 WHEN 'paused' THEN 1 WHEN 'completed' THEN 2 ELSE 3 END"))
  }
  scope :with_current_balance, lambda {
    left_outer_joins(:goal_contributions)
      .group(Arel.sql("goals.id"))
      .select(Arel.sql("goals.*, COALESCE(SUM(goal_contributions.amount), 0) AS current_balance_total"))
  }

  # 63-bit Postgres advisory-lock key per family. Used by future auto-fund flows
  # and any future per-family serialization of goal contributions.
  def self.advisory_lock_key_for(family_id)
    Digest::SHA1.hexdigest("goals:family:#{family_id}").to_i(16) % (2**63)
  end

  aasm column: :state do
    state :active, initial: true
    state :paused
    state :completed
    state :archived

    event :pause do
      transitions from: :active, to: :paused
    end

    event :resume do
      transitions from: :paused, to: :active
    end

    event :complete do
      transitions from: [ :active, :paused ], to: :completed
    end

    event :archive do
      transitions from: [ :active, :paused, :completed ], to: :archived
    end

    event :unarchive do
      transitions from: :archived, to: :active
    end
  end

  def current_balance
    @current_balance ||= if attributes.key?("current_balance_total")
      attributes["current_balance_total"] || 0
    else
      goal_contributions.sum(:amount)
    end
  end

  def current_balance_money
    @current_balance_money ||= Money.new(current_balance, currency)
  end

  def remaining_amount
    @remaining_amount ||= [ target_amount - current_balance, 0 ].max
  end

  def remaining_amount_money
    @remaining_amount_money ||= Money.new(remaining_amount, currency)
  end

  def progress_percent
    return @progress_percent if defined?(@progress_percent)

    @progress_percent = if completed?
      100
    elsif target_amount.to_d.zero?
      0
    else
      [ ((current_balance.to_d / target_amount.to_d) * 100).round, 100 ].min
    end
  end

  def months_remaining
    return nil unless target_date

    months = (target_date.year - Date.current.year) * 12 + (target_date.month - Date.current.month)
    [ months, 0 ].max
  end

  def monthly_target_amount
    return @monthly_target_amount if defined?(@monthly_target_amount)

    @monthly_target_amount = if target_date.nil?
      nil
    elsif months_remaining.zero?
      remaining_amount
    else
      (remaining_amount.to_d / months_remaining).ceil(2)
    end
  end

  # Segment array consumed by the shared `donut-chart` Stimulus controller
  # (see app/javascript/controllers/donut_chart_controller.js). Same shape
  # as Budget#to_donut_segments_json: filled portion in goal color, unused
  # remainder as the system "unallocated" fill.
  def to_donut_segments_json
    filled = current_balance.to_d
    rem = remaining_amount.to_d

    if filled.zero? && rem.zero?
      return [ { color: "var(--budget-unallocated-fill)", amount: 1, id: "unused" } ]
    end

    segments = []
    segments << { color: color.presence || "var(--color-blue-500)", amount: filled, id: "saved" } if filled.positive?
    segments << { color: "var(--budget-unallocated-fill)", amount: rem, id: "unused" } if rem.positive?
    segments
  end

  # Cumulative contributions series for the projection chart, sorted by
  # date ascending. Consumed by the
  # `goal-projection-chart` Stimulus controller.
  def projection_payload
    sorted = goal_contributions.sort_by(&:contributed_at)
    running = 0
    saved_series = sorted.map do |c|
      running += c.amount.to_d
      { date: c.contributed_at.to_s, value: running.to_f }
    end

    earliest = [ created_at.to_date, sorted.first&.contributed_at ].compact.min

    {
      saved_series: saved_series,
      start_date: earliest.to_s,
      today: Date.current.to_s,
      target_date: target_date&.to_s,
      target_amount: target_amount.to_f,
      current_amount: current_balance.to_f,
      avg_monthly: average_monthly_contribution.to_f,
      required_monthly: monthly_target_amount.to_f,
      currency: currency,
      status: status.to_s
    }
  end

  # Display-layer status. Prefers AASM state for inactive goals so the UI
  # doesn't compute a misleading "Behind / On track" verdict against a goal
  # that isn't accepting contributions anymore.
  def display_status
    return @display_status if defined?(@display_status)

    @display_status = if archived?
      :archived
    elsif paused?
      :paused
    else
      status
    end
  end

  # :reached → progress_percent >= 100
  # :on_track → has target_date and current pace >= required monthly pace
  # :behind → has target_date and current pace < required monthly pace
  # :no_target_date → progress < 100 and target_date is nil
  def status
    return @status if defined?(@status)

    @status = if progress_percent >= 100
      :reached
    elsif target_date.nil?
      :no_target_date
    elsif monthly_target_amount.to_d <= average_monthly_contribution.to_d
      :on_track
    else
      :behind
    end
  end

  def average_monthly_contribution
    return @average_monthly_contribution if defined?(@average_monthly_contribution)

    @average_monthly_contribution = if goal_contributions.empty?
      0
    else
      first_at = if goal_contributions.loaded?
        goal_contributions.map(&:contributed_at).compact.min
      else
        goal_contributions.minimum(:contributed_at)
      end
      if first_at.blank?
        current_balance
      else
        months = ((Date.current.year - first_at.year) * 12 + (Date.current.month - first_at.month)) + 1
        months = 1 if months < 1
        (current_balance.to_d / months).round(2)
      end
    end
  end

  def last_contribution_at
    @last_contribution_at ||= if goal_contributions.loaded?
      goal_contributions.map(&:contributed_at).compact.max
    else
      goal_contributions.maximum(:contributed_at)
    end
  end

  def last_contribution_days_ago
    last = last_contribution_at
    return nil if last.nil?

    (Date.current - last).to_i
  end

  private
    def must_have_at_least_one_linked_account
      return unless goal_accounts.reject(&:marked_for_destruction?).empty?

      errors.add(:base, :at_least_one_linked_account_required)
    end

    def linked_accounts_must_be_depository
      offending = goal_accounts.reject(&:marked_for_destruction?).reject do |sga|
        sga.account&.depository?
      end
      return if offending.empty?

      errors.add(:linked_accounts, :must_be_depository)
    end

    def linked_accounts_must_match_goal_currency
      return if currency.blank?

      mismatched = goal_accounts.reject(&:marked_for_destruction?).reject do |sga|
        sga.account.nil? || sga.account.currency == currency
      end
      return if mismatched.empty?

      errors.add(:linked_accounts, :currency_mismatch)
    end

    def linked_accounts_must_belong_to_family
      return if family.nil?

      foreign = goal_accounts.reject(&:marked_for_destruction?).reject do |sga|
        sga.account.nil? || sga.account.family_id == family_id
      end
      return if foreign.empty?

      errors.add(:linked_accounts, :must_belong_to_family)
    end

    # Once a goal has contributions, changing currency would orphan amounts
    # in the old currency. Lock it.
    def currency_locked_once_contributions_exist
      return unless persisted? && currency_changed?
      return unless goal_contributions.exists?

      errors.add(:currency, :locked_after_contributions)
    end
end
