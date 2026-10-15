module CommoditiesTestHelper
  def create_commodity_account(family: families(:dylan_family), currency: "USD", name: Commodity::DEFAULT_ACCOUNT_NAME, owner: nil)
    family.accounts.create!(
      name: name,
      currency: currency,
      balance: 0,
      owner: owner || (family == families(:dylan_family) ? users(:family_admin) : family.users.first),
      accountable: Commodity.new
    )
  end

  def create_commodity_item(account:, **attributes)
    account.commodity_items.create!({
      code: "XAU",
      name: "1 oz Maple Leaf",
      form: "coin",
      quantity: 1,
      weight_value: 1,
      weight_unit: "ozt",
      fineness: BigDecimal("0.9999"),
      purchase_date: 10.days.ago.to_date,
      purchase_currency: account.currency,
      metal_cost: 2000
    }.merge(attributes))
  end

  def create_commodity_price(code:, date:, price:, currency: "USD", source: "metal_price_api")
    Commodity::Price.create!(code: code, date: date, price: price, currency: currency, source: source)
  end

  def create_rate(from:, to:, date:, rate:)
    ExchangeRate.create!(from_currency: from, to_currency: to, date: date, rate: rate)
  end
end
