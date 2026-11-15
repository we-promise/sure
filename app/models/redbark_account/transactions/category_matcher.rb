# frozen_string_literal: true

# Auto-matches a Redbark transaction's bank-assigned category to one of the family's
# existing Sure categories. Mirrors MonobankAccount::Transactions::CategoryMatcher: a fast,
# cheap, high-confidence pass that never creates categories and never overwrites user data
# (the import adapter applies the result via enrich_attribute, which respects locks). The
# category table lives in RedbarkAccount::Transactions::CategoryTaxonomy, the MCC table in
# the shared Transactions::MccTaxonomy.
#
# `category` (Redbark's fixed bank-category code) is the primary signal: it already
# describes spending purpose, not just merchant type. `merchant_category_code` (MCC) is a
# strictly secondary one, used only as a fallback when `category` is blank, unrecognised,
# or one of the codes intentionally left unmapped (too coarse/ambiguous to trust). It never
# overrides or narrows a recognised code: a recognised code whose category the family does
# not have stays uncategorised rather than being reassigned by merchant type.
#
# Redbark does report supermarket purchases as FOOD_AND_DRINK + MCC 5411, so a grocery shop
# lands in "Food & Drink" here rather than "Groceries". That is left to the rules engine
# instead of being special-cased in the taxonomy: the processor stores the MCC in
# transactions.extra, which Rule::ConditionFilter::TransactionDetails can match, so a user
# who wants that split can express it as a rule without changing the signal hierarchy for
# everyone.
#
# Locale-aware like the Monobank matcher: a Redbark-linked family is not necessarily
# English-speaking, so the family's own locale is tried before the English aliases.
class RedbarkAccount::Transactions::CategoryMatcher
  include RedbarkAccount::Transactions::CategoryTaxonomy
  include Transactions::LocaleAwareCategoryMatching

  # @param user_categories [Array<Category>] the family's existing categories
  # @param locale [String, Symbol, nil] the family's locale, used to compare against
  #   default category names as the family sees them
  def initialize(user_categories = [], locale: nil)
    @user_categories = user_categories
    @locale = locale
  end

  # category is the transaction's `category` field (Redbark's fixed bank-category code,
  # e.g. "FOOD_AND_DRINK"). mcc is its `merchant_category_code`. Returns a matching
  # Category, or nil when neither signal has an equivalent among the user's categories.
  def match(category, mcc = nil)
    group = category_group(category)
    return match_group(group) if group

    match_group(mcc_group(mcc))
  end

  private
    attr_reader :user_categories, :locale
end
