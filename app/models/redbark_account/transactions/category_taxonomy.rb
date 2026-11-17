# frozen_string_literal: true

# Maps Redbark's fixed bank-category codes (GET /v1/categories, the `category` field on a
# transaction) onto the family's existing Sure categories. The MCC fallback table is the
# shared Transactions::MccTaxonomy.
#
# Redbark assigns one of 16 fixed, CDR-enriched codes to every transaction. Unlike a
# Merchant Category Code, these already describe spending *purpose* rather than merchant
# type, so no numeric lookup table is needed -- the raw string is the key. The full set,
# per Redbark's docs, is: BANK_FEES, ENTERTAINMENT, FOOD_AND_DRINK,
# GOVERNMENT_AND_NON_PROFIT, HOME_IMPROVEMENT, INCOME, LOAN_PAYMENTS, MEDICAL, MERCHANDISE,
# PERSONAL_CARE, RENT_AND_UTILITIES, SERVICES, TRANSFER_IN, TRANSFER_OUT, TRANSPORTATION,
# TRAVEL.
#
# NOTE: these are Redbark API *v1* codes, and `category` is a v1 field. The v2 migration
# (issue #4311) replaces it with `provider_category`, whose values are not these. An
# unrecognised code falls through to the MCC table, so after a v2 switch this matcher would
# quietly degrade to MCC-only rather than failing loudly. CategoryMatcherTest pins the v1
# codes so that migration breaks a test instead.
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
# LOAN_PAYMENTS is mapped, deliberately, even though real Redbark data shows credit-card
# repayments arriving under it with no MCC. The code cannot distinguish a card payoff from
# a mortgage or personal-loan repayment, and the card case is already handled downstream:
# when the card is linked, transfer detection classifies the payment as a cc_payment, and
# Transaction::BUDGET_EXCLUDED_KINDS keeps those out of budget analytics whatever category
# sits on them. Excluding the code would instead lose a useful category on every repayment
# to a loan or card Sure does not hold.
#
# A wrong auto-category is worse than none: the import adapter applies matches via
# enrich_attribute, so anything left unmapped simply stays uncategorised for the user's own
# rules (or the AI categoriser) to handle.
module RedbarkAccount::Transactions::CategoryTaxonomy
  include Transactions::MccTaxonomy

  # Each group carries two ways of finding the user's category:
  #
  # * `key` is the Sure default-category translation key
  #   (Category::DEFAULT_CATEGORY_TRANSLATION_KEYS), so the matcher can compare against
  #   the category name as the family actually sees it in their own locale.
  # * `aliases` are English fallbacks, matched case/punctuation-insensitively, which also
  #   cover categories the user renamed or created by hand.
  CATEGORY_GROUPS = {
    "BANK_FEES"        => { key: :fees,             aliases: [ "fees" ] },
    "ENTERTAINMENT"    => { key: :entertainment,     aliases: [ "entertainment" ] },
    "FOOD_AND_DRINK"   => { key: :food_and_drink,    aliases: [ "food and drink", "dining", "restaurants" ] },
    "HOME_IMPROVEMENT" => { key: :home_improvement,  aliases: [ "home improvement" ] },
    "INCOME"           => { key: :income,            aliases: [ "income" ] },
    "LOAN_PAYMENTS"    => { key: :loan_payments,     aliases: [ "loan payments" ] },
    "MEDICAL"          => { key: :healthcare,        aliases: [ "healthcare", "health", "medical" ] },
    "PERSONAL_CARE"    => { key: :personal_care,     aliases: [ "personal care" ] },
    "SERVICES"         => { key: :services,          aliases: [ "services" ] },
    "TRANSPORTATION"   => { key: :transportation,    aliases: [ "transportation", "transport" ] },
    "TRAVEL"           => { key: :travel,            aliases: [ "travel" ] }
  }.freeze

  # The taxonomy group for a Redbark category code, or nil when the code is unknown or has
  # no confident mapping.
  #
  # @param category [String, nil] the transaction's `category` field, e.g. "FOOD_AND_DRINK"
  def category_group(category)
    return nil if category.blank?

    RedbarkAccount::Transactions::CategoryTaxonomy::CATEGORY_GROUPS[category.to_s.upcase]
  end
end
