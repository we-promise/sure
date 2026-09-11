class UI::Account::ValuableOverview < ApplicationComponent
  BullionSummary = Data.define(:material, :gross_weight, :fine_weight, :purity, :rate)

  attr_reader :account

  def initialize(account:)
    @account = account
  end

  def valuable = account.valuable

  def items
    @items ||= valuable.items.includes(:merchant, invoice_attachment: :blob).order(acquired_on: :desc).to_a
  end

  def bullion_summaries
    @bullion_summaries ||= bullion_items.group_by(&:material).map do |material, material_items|
      gross_weight = material_items.sum(&:weight_in_grams)
      fine_weight = material_items.sum(&:fine_weight_in_grams)

      BullionSummary.new(
        material:,
        gross_weight:,
        fine_weight:,
        purity: fine_weight / gross_weight * 100,
        rate: rate_for_symbol(ValuableItem::BULLION_MATERIALS.fetch(material))
      )
    end
  end

  def gemstones = @gemstones ||= items.select(&:gemstone?)
  def gemstones_value = gemstones.sum { |item| item.manual_value.to_d }
  def gemstones_weight = gemstones.sum { |item| item.weight.to_d }
  def rate_for(item)
    rate_for_symbol(item.quote_symbol) if item.spot_valued?
  end

  def item_value(item)
    rate = rate_for(item)
    Money.new(item.value_for(rate&.rate), account.currency) if item.manual_value? || rate
  end

  def item_gain(item)
    value = item_value(item)
    return unless value

    value - Money.new(item.total_cost_amount, account.currency)
  end

  def item_return_percentage(item)
    return if item.total_cost_amount.zero? || item_gain(item).zero?

    item_gain(item).amount / item.total_cost_amount * 100
  end

  def editable? = account.permission_for(Current.user).in?([ :owner, :full_control ])

  private
    def bullion_items = @bullion_items ||= items.select(&:bullion?)

    def rates_by_symbol
      @rates_by_symbol ||= ExchangeRate.where(from_currency: bullion_items.filter_map(&:quote_symbol).uniq, to_currency: account.currency)
        .order(date: :desc)
        .to_a
        .group_by(&:from_currency)
        .transform_values(&:first)
    end

    def rate_for_symbol(symbol) = rates_by_symbol[symbol]
end
