class GoalContribution < ApplicationRecord
  include Monetizable

  SOURCES = %w[manual initial].freeze

  belongs_to :goal
  belongs_to :account

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :contributed_at, presence: true
  validates :source, inclusion: { in: SOURCES }
  validate :currency_matches_goal
  validate :account_must_belong_to_family
  validate :account_must_be_linked_to_goal

  before_validation :sync_currency_from_goal

  monetize :amount

  scope :chronological, -> { order(contributed_at: :desc, created_at: :desc) }

  def manual?
    source == "manual"
  end

  def initial?
    source == "initial"
  end

  private
    def sync_currency_from_goal
      self.currency = goal.currency if goal && currency.blank?
    end

    def currency_matches_goal
      return if goal.nil? || currency.blank?
      return if currency == goal.currency

      errors.add(:currency, :must_match_goal)
    end

    def account_must_belong_to_family
      return if goal.nil? || account.nil?
      return if account.family_id == goal.family_id

      errors.add(:account, :must_belong_to_family)
    end

    def account_must_be_linked_to_goal
      return if goal.nil? || account.nil?
      return if goal.goal_accounts.where(account_id: account_id).exists?

      errors.add(:account, :must_be_linked_to_goal)
    end
end
