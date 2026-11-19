class EquityVest < ApplicationRecord
  include Monetizable

  belongs_to :equity_grant, inverse_of: :vests
  belongs_to :account_statement, optional: true

  enum :source, EquityGrant::SOURCES.index_by(&:itself), validate: true, prefix: :from

  monetize :net_proceeds

  validates :vest_date, presence: true
  validates :units, numericality: { greater_than: 0 }
  validates :units_withheld, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  before_validation { self.currency ||= equity_grant&.account&.currency }

  def vested?(as_of: Date.current)
    vest_date <= as_of
  end

  # Value at the latest known price, for upcoming vests.
  def estimated_value
    price = equity_grant.latest_price
    price && price * units
  end
end
