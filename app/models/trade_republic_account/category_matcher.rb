class TradeRepublicAccount::CategoryMatcher
  RULES = {
    "Groceries" => %w[aldi aldi-süd lidl rewe edeka kaufland marktkauf supermarkt nahkauf netto penny tesco grocery],
    "Restaurants & Dining" => %w[restaurant mcdonald burger king lieferando wolt uber eats cafe café bakery bäckerei],
    "Transportation" => %w[tankstelle shell aral esso uber taxi deutsche bahn db bahn bolt],
    "Subscriptions" => [ "netflix", "spotify", "apple.com", "amazon prime", "adobe", "openai", "cursor" ],
    "Fees & Charges" => %w[gebühr fee atm],
    "Shopping" => %w[amazon zalando ebay ikea media markt saturn]
  }.freeze

  def initialize(family)
    @family = family
  end

  def category_for(text)
    normalized = text.to_s.downcase
    return if normalized.blank?

    category_name = RULES.find do |_name, keywords|
      keywords.any? { |keyword| normalized.include?(keyword) }
    end&.first
    return if category_name.blank?

    family.categories.find { |category| category.name.casecmp?(category_name) }
  end

  private

    attr_reader :family
end
