class EquityVest < ApplicationRecord
  include Monetizable

  belongs_to :equity_grant, inverse_of: :vests
  belongs_to :account_statement, optional: true

  enum :source, EquityGrant::SOURCES.index_by(&:itself), validate: true, prefix: :from

  monetize :net_proceeds

  validates :vest_date, presence: true, uniqueness: { scope: :equity_grant_id }
  validates :units, numericality: { greater_than: 0 }
  validates :units_withheld, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  before_validation { self.currency ||= equity_grant&.account&.currency }

  def vested?(as_of: Date.current)
    vest_date <= as_of && !forfeited?
  end

  # A vest scheduled after the grant was forfeited never happens.
  def forfeited?
    equity_grant.forfeited_on.present? && vest_date > equity_grant.forfeited_on
  end

  # Value at the latest known price, for upcoming vests.
  def estimated_value
    unit_value = equity_grant.unit_value
    unit_value && unit_value * units
  end
end
