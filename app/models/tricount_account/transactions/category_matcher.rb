# frozen_string_literal: true

# Matches a Tricount expense category to one of the family's existing Sure
# categories by name. It never creates a category, and the import adapter
# applies the result as an enrichment, so a category the user set or locked is
# kept. A category with no confident match is left to rules and the AI.
class TricountAccount::Transactions::CategoryMatcher
  # Tricount's categories, normalised (lower case, letters only), to the Sure
  # category names they correspond to, best first.
  ALIASES = {
    "food" => [ "Food & Drink", "Restaurants", "Dining Out" ],
    "foodanddrink" => [ "Food & Drink", "Restaurants", "Dining Out" ],
    "restaurant" => [ "Restaurants", "Food & Drink", "Dining Out" ],
    "restaurants" => [ "Restaurants", "Food & Drink", "Dining Out" ],
    "drinks" => [ "Food & Drink", "Bars" ],
    "groceries" => [ "Groceries", "Food & Drink" ],
    "accommodation" => [ "Travel", "Accommodation", "Lodging", "Hotels" ],
    "lodging" => [ "Travel", "Accommodation", "Lodging", "Hotels" ],
    "transport" => [ "Transportation", "Travel" ],
    "transportation" => [ "Transportation", "Travel" ],
    "travel" => [ "Travel", "Transportation" ],
    "entertainment" => [ "Entertainment" ],
    "leisure" => [ "Entertainment" ],
    "shopping" => [ "Shopping" ],
    "health" => [ "Healthcare", "Health" ],
    "healthcare" => [ "Healthcare", "Health" ],
    "rent" => [ "Rent & Utilities", "Housing", "Rent" ],
    "housing" => [ "Housing", "Rent & Utilities" ],
    "utilities" => [ "Utilities", "Rent & Utilities" ],
    "fees" => [ "Fees" ],
    "gifts" => [ "Gifts & Donations", "Gifts" ],
    "sport" => [ "Sports", "Entertainment" ],
    "sports" => [ "Sports", "Entertainment" ]
  }.freeze

  def initialize(categories)
    @by_name = categories.index_by { |category| normalize(category.name) }
  end

  # The family's category for a Tricount category, or nil.
  def match(tricount_category)
    key = normalize(tricount_category)
    return nil if key.empty?

    [ tricount_category.to_s, *ALIASES.fetch(key, []) ].each do |name|
      category = @by_name[normalize(name)]
      return category if category
    end
    nil
  end

  private

    def normalize(name)
      name.to_s.downcase.gsub("&", "and").gsub(/[^a-z]/, "")
    end
end
