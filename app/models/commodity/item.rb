# A physical commodity item (bar, coin, ...) held in a Commodity account.
#
# Weight is stored per piece in grams; valuation uses fine weight
# (gross weight x fineness). Purchase amounts are totals for all pieces in the
# purchase currency and are converted to the account currency at the
# purchase-date rate. A missing rate makes the cost basis unknown (nil), never
# zero — the same convention as Trade#realized_gain_loss.
class Commodity::Item < ApplicationRecord
  FORMS = %w[bar coin round granules other].freeze
  SELL_BACK_MODES = %w[spot_percent per_piece].freeze

  # Cost basis in the account currency, split into its components.
  CostBasis = Data.define(:metal, :premium, :other) do
    def total
      metal + premium + other
    end

    def premium_and_costs
      premium + other
    end
  end

  belongs_to :account
  belongs_to :location, class_name: "Commodity::Location", optional: true, inverse_of: :items
  has_many :sales, -> { order(:date, :created_at) }, class_name: "Commodity::Sale", foreign_key: :item_id, inverse_of: :item, dependent: :destroy
  has_many :moves, -> { order(:moved_on, :created_at) }, class_name: "Commodity::ItemMove", foreign_key: :item_id, inverse_of: :item, dependent: :destroy

  has_one_attached :photo

  # Weight as entered (in `weight_unit`); converted to grams on save.
  attribute :weight_value, :decimal

  validates :name, :purchase_date, :purchase_currency, presence: true
  validates :code, inclusion: { in: ->(_) { Commodity::CATALOG.map(&:code) } }
  validates :form, inclusion: { in: FORMS }
  validates :weight_unit, inclusion: { in: Commodity::Weight::UNITS }
  validates :quantity, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :gross_weight_grams, numericality: { greater_than: 0 }
  validates :fineness, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :metal_cost, :premium, :vat, :shipping, :insurance, numericality: { greater_than_or_equal_to: 0 }
  validates :sell_back_mode, inclusion: { in: SELL_BACK_MODES }, allow_nil: true
  validates :sell_back_value, numericality: { greater_than_or_equal_to: 0 }, if: :sell_back_mode
  validate :account_is_commodity
  validate :quantity_covers_sales

  before_validation :apply_weight_value
  before_validation :sync_remaining_quantity

  scope :held, -> { where("commodity_items.remaining_quantity > 0") }
  scope :sold, -> { where(remaining_quantity: 0) }

  delegate :currency, to: :account

  class << self
    # Exchange-rate pairs (with the earliest date needed) to value the items in
    # this scope: price currency, purchase currency and sale currency, each
    # into the account currency. Returns { [from, to] => date }.
    def exchange_rate_start_dates
      pairs = {}
      add = ->(from, to, date) do
        next if from == to || date.nil?
        pairs[[ from, to ]] = [ pairs[[ from, to ]], date ].compact.min
      end

      price_currencies = Commodity::Price.distinct.pluck(:currency).presence || [ "USD" ]
      joins(:account).group("accounts.currency").minimum(:purchase_date).each do |account_currency, date|
        price_currencies.each { |currency| add.call(currency, account_currency, date) }
      end

      joins(:account).group(:purchase_currency, "accounts.currency").minimum(:purchase_date).each do |(from, to), date|
        add.call(from, to, date)
      end

      Commodity::Sale.where(item_id: select(:id)).joins(item: :account)
        .group("commodity_sales.currency", "accounts.currency").minimum("commodity_sales.date").each do |(from, to), date|
        add.call(from, to, date)
      end

      pairs
    end
  end

  def metal
    Commodity.metal(code)
  end

  def weight_value
    super || (gross_weight_grams && Commodity::Weight.from_grams(gross_weight_grams, weight_unit).round(6))
  end

  def held?
    remaining_quantity.positive?
  end

  def sold_quantity
    quantity - remaining_quantity
  end

  def fine_grams(qty = remaining_quantity)
    gross_weight_grams * fineness * qty
  end

  def gross_grams(qty = remaining_quantity)
    gross_weight_grams * qty
  end

  def fine_troy_ounces(qty = remaining_quantity)
    Commodity::Weight.from_grams(fine_grams(qty), "ozt")
  end

  def other_costs
    vat + shipping + insurance
  end

  # Cost basis of `qty` pieces, proportional to the item's full purchase.
  def cost_basis(qty = remaining_quantity)
    @full_cost_basis = full_cost_basis unless defined?(@full_cost_basis)
    return nil if @full_cost_basis.nil?

    share = BigDecimal(qty.to_s) / quantity
    CostBasis.new(
      metal: @full_cost_basis.metal * share,
      premium: @full_cost_basis.premium * share,
      other: @full_cost_basis.other * share
    )
  end

  def spot_price(date: Date.current)
    Commodity::Price.per_troy_ounce(code, date: date, currency: currency)
  end

  def melt_value(date: Date.current, qty: remaining_quantity)
    price = spot_price(date: date)
    price && price * fine_troy_ounces(qty)
  end

  # Unrealized P&L = melt value - total cost basis.
  def unrealized_trend(date: Date.current)
    melt = melt_value(date: date)
    basis = cost_basis
    return nil if melt.nil? || basis.nil?

    Trend.new(current: melt, previous: basis.total)
  end

  # The part of the P&L caused by the metal price: melt value - metal cost.
  def metal_gain(date: Date.current)
    melt = melt_value(date: date)
    basis = cost_basis
    melt && basis && melt - basis.metal
  end

  # What a dealer would pay for the held pieces, if a sell-back price is set.
  def realisable_value(date: Date.current)
    case sell_back_mode
    when "spot_percent"
      melt = melt_value(date: date)
      melt && melt * (sell_back_value / 100)
    when "per_piece"
      Money.new(sell_back_value * remaining_quantity, currency)
    end
  end

  def realisable_trend(date: Date.current)
    value = realisable_value(date: date)
    basis = cost_basis
    return nil if value.nil? || basis.nil?

    Trend.new(current: value, previous: basis.total)
  end

  def move_to!(new_location, on: Date.current)
    return if new_location&.id == location_id

    transaction do
      moves.create!(from_location: location, to_location: new_location, moved_on: on)
      update!(location: new_location)
    end
  end

  def recalculate_remaining_quantity!
    update!(remaining_quantity: quantity - sales.sum(:quantity))
  end

  private
    def full_cost_basis
      CostBasis.new(
        metal: to_account_currency(metal_cost),
        premium: to_account_currency(premium),
        other: to_account_currency(other_costs)
      )
    rescue Money::ConversionError
      nil
    end

    def to_account_currency(amount)
      Money.new(amount, purchase_currency).exchange_to(currency, date: purchase_date)
    end

    def apply_weight_value
      raw = read_attribute(:weight_value)
      self.gross_weight_grams = Commodity::Weight.to_grams(raw, weight_unit) if raw.present?
    end

    def sync_remaining_quantity
      return unless quantity

      sold = new_record? ? 0 : sales.sum(:quantity)
      self.remaining_quantity = quantity - sold
    end

    def account_is_commodity
      errors.add(:account, :invalid) unless account&.accountable_type == "Commodity"
    end

    def quantity_covers_sales
      errors.add(:quantity, :less_than_sold) if remaining_quantity && remaining_quantity.negative?
    end
end
