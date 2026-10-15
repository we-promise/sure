# A (partial) sale of an item's pieces. Proceeds and costs are totals in the
# sale currency.
class Commodity::Sale < ApplicationRecord
  belongs_to :item, class_name: "Commodity::Item", inverse_of: :sales

  # Form input: proceeds entered per piece or as a total (stored as a total).
  attribute :proceeds_basis, :string, default: "total"

  before_validation :apply_proceeds_basis

  validates :date, :currency, presence: true
  validates :quantity, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :proceeds, :costs, numericality: { greater_than_or_equal_to: 0 }
  validate :quantity_available
  validate :not_before_purchase

  # Held quantity changes in the same transaction as the sale.
  after_save :refresh_remaining_quantity
  after_destroy :refresh_remaining_quantity, unless: :destroyed_by_association
  after_commit :sync_account, unless: :destroyed_by_association

  # Realized P&L = proceeds - sale costs - proportional cost basis of the pieces
  # sold, in the account currency. nil when an exchange rate is missing.
  def realized_gain_loss
    return @realized_gain_loss if defined?(@realized_gain_loss)

    basis = item.cost_basis(quantity)
    net_proceeds = Money.new(proceeds - costs, currency).exchange_to(item.currency, date: date)
    @realized_gain_loss = basis && Trend.new(current: net_proceeds, previous: basis.total)
  rescue Money::ConversionError
    @realized_gain_loss = nil
  end

  private
    def apply_proceeds_basis
      self.proceeds = proceeds * quantity if proceeds_basis == "per_piece" && proceeds && quantity
      self.proceeds_basis = "total"
    end

    def quantity_available
      return unless item && quantity

      already_sold = item.sales.where.not(id: id).sum(:quantity)
      errors.add(:quantity, :exceeds_held) if already_sold + quantity > item.quantity
    end

    def not_before_purchase
      errors.add(:date, :before_purchase) if item && date && date < item.purchase_date
    end

    def refresh_remaining_quantity
      item.recalculate_remaining_quantity!
    end

    def sync_account
      item.account.sync_later
    end
end
