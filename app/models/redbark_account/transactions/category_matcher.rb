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
# noisier signal and is used in only two ways:
#
# * as a *fallback*, when `category` is blank, unrecognised, or one of the codes
#   intentionally left unmapped (too coarse/ambiguous to trust);
# * as a *refinement*, when the code permits it in CATEGORY_MCC_REFINEMENTS -- narrowing a
#   recognised code to a more specific category inside the same domain.
#
# It is never allowed to override a recognised code with something unrelated: a recognised
# code whose category the family does not have stays uncategorised rather than being
# reassigned by merchant type.
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

    if group
      refinement = category_refinement_group(category, mcc)
      return match_group(refinement) || match_group(group) if refinement

      return match_group(group)
    end

    match_group(mcc_group(mcc))
  end

  private
    attr_reader :user_categories, :locale
end
