class SavingsGoal < ApplicationRecord
  include AASM, Monetizable

  belongs_to :family
  belongs_to :account
  has_many :savings_contributions, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :target_amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validate :account_belongs_to_family
  validate :account_is_asset
  validate :currency_locked_once_contributions_exist

  before_validation :sync_currency_from_account

  monetize :target_amount

  scope :alphabetically, -> { order(Arel.sql("LOWER(name) ASC")) }
  scope :active_first,
        -> { order(Arel.sql("CASE state WHEN 'active' THEN 0 WHEN 'paused' THEN 1 WHEN 'completed' THEN 2 ELSE 3 END")) }

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
    savings_contributions.sum(:amount) || 0
  end

  def current_balance_money
    Money.new(current_balance, currency)
  end

  def remaining_amount
    [ target_amount - current_balance, 0 ].max
  end

  def remaining_amount_money
    Money.new(remaining_amount, currency)
  end

  def progress_percent
    return 100 if completed?
    return 0 if target_amount.to_d.zero?
    [ ((current_balance.to_d / target_amount.to_d) * 100).round, 100 ].min
  end

  def months_remaining
    return nil unless target_date
    months = (target_date.year - Date.current.year) * 12 + (target_date.month - Date.current.month)
    [ months, 0 ].max
  end

  def monthly_target_amount
    return nil unless target_date
    months = months_remaining
    return remaining_amount if months.zero?
    (remaining_amount.to_d / months).ceil(2)
  end

private
  def sync_currency_from_account
    self.currency = account.currency if account
  end

  def account_belongs_to_family
    return if account.nil? || family.nil?
    errors.add(:account, "must belong to the same family") unless account.family_id == family_id
  end

  def account_is_asset
    return if account.nil?
    errors.add(:account, "must be an asset account") unless account.classification == "asset"
  end

  # Once a goal has contributions, swapping its account to one in a
  # different currency would orphan those contributions in the old
  # currency while the goal flips to the new one — current_balance
  # would silently sum across currencies. Block the change.
  def currency_locked_once_contributions_exist
    return unless persisted? && account.present?
    return if savings_contributions.none?

    existing_currency = savings_contributions.first.currency
    return if existing_currency.blank? || existing_currency == account.currency
    errors.add(:account, "cannot be changed to a different currency once the goal has contributions")
  end
end
