# frozen_string_literal: true

# Maps Redbark's fixed bank-category codes (GET /v1/categories, the `category` field on a
# transaction) onto the family's existing Sure categories.
#
# Redbark assigns one of 16 fixed, CDR-enriched codes to every transaction. Unlike a
# Merchant Category Code, these already describe spending *purpose* rather than merchant
# type, so no numeric lookup table is needed -- the raw string is the key. The full set,
# per Redbark's docs, is: BANK_FEES, ENTERTAINMENT, FOOD_AND_DRINK,
# GOVERNMENT_AND_NON_PROFIT, HOME_IMPROVEMENT, INCOME, LOAN_PAYMENTS, MEDICAL, MERCHANDISE,
# PERSONAL_CARE, RENT_AND_UTILITIES, SERVICES, TRANSFER_IN, TRANSFER_OUT, TRANSPORTATION,
# TRAVEL.
#
# Codes with no honest Sure equivalent are intentionally absent:
#
# * TRANSFER_IN / TRANSFER_OUT -- money movement, not spending; Sure's transfer matcher
#   pairs these up instead.
# * MERCHANDISE -- too coarse to trust: it covers everything from groceries to electronics,
#   and guessing "Shopping" for all of it would misclassify routine grocery runs.
# * RENT_AND_UTILITIES -- Sure keeps "Mortgage / Rent" and "Utilities" as separate
#   defaults; Redbark's single code can't be split between them with any confidence.
# * GOVERNMENT_AND_NON_PROFIT -- lumps tax/government payments together with charitable
#   donations, two categories with nothing in common.
#
# A wrong auto-category is worse than none: the import adapter applies matches via
# enrich_attribute, so anything left unmapped simply stays uncategorised for the user's own
# rules (or the AI categoriser) to handle.
module RedbarkAccount::Transactions::CategoryTaxonomy
  # Each group carries two ways of finding the user's category:
  #
  # * `key` is the Sure default-category translation key
  #   (Category::DEFAULT_CATEGORY_TRANSLATION_KEYS), so the matcher can compare against
  #   the category name as the family actually sees it in their own locale.
  # * `aliases` are English fallbacks, matched case/punctuation-insensitively, which also
  #   cover categories the user renamed or created by hand.
  CATEGORY_GROUPS = {
    "BANK_FEES"       => { key: :fees,            aliases: [ "fees" ] },
    "ENTERTAINMENT"   => { key: :entertainment,    aliases: [ "entertainment" ] },
    "FOOD_AND_DRINK"  => { key: :food_and_drink,   aliases: [ "food and drink", "dining", "restaurants" ] },
    "HOME_IMPROVEMENT" => { key: :home_improvement, aliases: [ "home improvement" ] },
    "INCOME"          => { key: :income,           aliases: [ "income" ] },
    "LOAN_PAYMENTS"   => { key: :loan_payments,     aliases: [ "loan payments" ] },
    "MEDICAL"         => { key: :healthcare,       aliases: [ "healthcare", "health", "medical" ] },
    "PERSONAL_CARE"   => { key: :personal_care,     aliases: [ "personal care" ] },
    "SERVICES"        => { key: :services,         aliases: [ "services" ] },
    "TRANSPORTATION"  => { key: :transportation,    aliases: [ "transportation", "transport" ] },
    "TRAVEL"          => { key: :travel,           aliases: [ "travel" ] }
  }.freeze

  # The taxonomy group for a Redbark category code, or nil when the code is unknown or has
  # no confident mapping.
  #
  # @param category [String, nil] the transaction's `category` field, e.g. "FOOD_AND_DRINK"
  def category_group(category)
    return nil if category.blank?

    RedbarkAccount::Transactions::CategoryTaxonomy::CATEGORY_GROUPS[category.to_s.upcase]
  end

  # Fallback table for when `category` is blank or one of the codes intentionally excluded
  # above (MERCHANDISE, RENT_AND_UTILITIES, GOVERNMENT_AND_NON_PROFIT, TRANSFER_IN,
  # TRANSFER_OUT). `merchant_category_code` (ISO 18245) is a noisier signal -- it describes
  # the merchant's business type, not spending purpose -- so this table mirrors
  # MonobankAccount::Transactions::CategoryTaxonomy's deliberately conservative groupings
  # and the same exclusions: cash/quasi-cash/transfers (money movement, not spending),
  # alcohol/tobacco/gambling (most people track these under their own categories, if at
  # all), and education (no Sure default category).
  MCC_GROUPS = [
    {
      key: :groceries,
      aliases: [ "groceries" ],
      mccs: [ 5411, 5422, 5441, 5451, 5462, 5499 ]
    },
    {
      key: :food_and_drink,
      aliases: [ "food and drink", "dining", "restaurants" ],
      mccs: [ 5811, 5812, 5813, 5814 ]
    },
    {
      key: :transportation,
      aliases: [ "transportation", "transport" ],
      mccs: [ 4111, 4112, 4121, 4131, 4789, 5533, 5541, 5542, 7523, 7531, 7534, 7538, 7549 ]
    },
    {
      key: :travel,
      aliases: [ "travel" ],
      mccs: [ 4411, 4457, 4511, 4722, 7011, 7512, 7513, 7519 ],
      mcc_ranges: [ 3000..3299, 3500..3999 ]
    },
    {
      key: :entertainment,
      aliases: [ "entertainment" ],
      mccs: [ 7832, 7911, 7922, 7929, 7991, 7993, 7994, 7996, 7998, 7999 ]
    },
    {
      key: :healthcare,
      aliases: [ "healthcare", "health" ],
      mccs: [ 5912, 5975, 5976, 8011, 8021, 8031, 8041, 8042, 8043, 8049, 8050, 8062, 8071, 8099 ]
    },
    {
      key: :personal_care,
      aliases: [ "personal care" ],
      mccs: [ 5977, 7230, 7297, 7298 ]
    },
    {
      key: :sports_and_fitness,
      aliases: [ "sports and fitness", "fitness" ],
      mccs: [ 5941, 7941, 7997 ]
    },
    {
      key: :shopping,
      aliases: [ "shopping" ],
      mccs: [
        5300, 5310, 5311, 5399, 5611, 5621, 5631, 5641, 5651, 5655, 5661, 5691, 5699,
        5712, 5713, 5714, 5719, 5722, 5732, 5733, 5734, 5735, 5931, 5942, 5943, 5945,
        5946, 5948, 5949, 5950, 5970, 5999
      ]
    },
    {
      key: :home_improvement,
      aliases: [ "home improvement" ],
      mccs: [ 1520, 1711, 1731, 1740, 1750, 1761, 1771, 5200, 5211, 5231, 5251, 5261 ]
    },
    {
      key: :utilities,
      aliases: [ "utilities" ],
      mccs: [ 4812, 4813, 4814, 4900 ]
    },
    {
      key: :subscriptions,
      aliases: [ "subscriptions" ],
      mccs: [ 5815 ]
    },
    {
      key: :insurance,
      aliases: [ "insurance" ],
      mccs: [ 5960, 6300 ]
    },
    {
      key: :mortgage_rent,
      aliases: [ "mortgage rent", "rent", "mortgage" ],
      mccs: [ 6513 ]
    },
    {
      key: :gifts_and_donations,
      aliases: [ "gifts and donations", "donations", "charity" ],
      mccs: [ 8398 ]
    },
    {
      key: :taxes,
      aliases: [ "taxes", "tax" ],
      mccs: [ 9311 ]
    },
    {
      key: :services,
      aliases: [ "services" ],
      mccs: [
        4215, 7210, 7216, 7217, 7221, 7251, 7261, 7276, 7277, 7299, 7311, 7392, 7393,
        7399, 8111, 8931, 9402
      ]
    }
  ].freeze

  # { 5411 => group } lookup built from MCC_GROUPS. Ranges are expanded once at first use;
  # the whole table is only a few thousand small integer keys.
  def self.group_by_mcc
    @group_by_mcc ||= MCC_GROUPS.each_with_object({}) do |group, map|
      codes = Array(group[:mccs]) + Array(group[:mcc_ranges]).flat_map(&:to_a)

      codes.each { |mcc| map[mcc] ||= group }
    end.freeze
  end

  # The MCC fallback group for a Merchant Category Code, or nil when the code has no
  # confident mapping.
  #
  # @param mcc [Integer, String, nil] the transaction's `merchant_category_code` field
  def mcc_group(mcc)
    return nil if mcc.blank?

    code = Integer(mcc.to_s, exception: false)
    return nil if code.nil?

    RedbarkAccount::Transactions::CategoryTaxonomy.group_by_mcc[code]
  end
end
