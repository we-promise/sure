# Auto-matches a Monobank transaction's MCC to one of the family's existing Sure
# categories. Mirrors PlaidAccount::Transactions::CategoryMatcher and its Up equivalent:
# a fast, cheap, high-confidence pass that never creates categories and never overwrites
# user data (the import adapter applies the result via enrich_attribute, which respects
# locks). The MCC table lives in Transactions::MccTaxonomy.
#
# Unlike the Plaid and Up matchers, matching is locale-aware. Those providers hand over
# an English category slug and are matched against English aliases, which quietly
# matches nothing for a family whose categories are named in their own language.
# Monobank's users are Ukrainian by definition, so each MCC group also carries the Sure
# default-category translation key and the family's own locale is tried first.
class MonobankAccount::Transactions::CategoryMatcher
  include MonobankAccount::Transactions::CategoryTaxonomy
  include Transactions::LocaleAwareCategoryMatching

  # @param user_categories [Array<Category>] the family's existing categories
  # @param locale [String, Symbol, nil] the family's locale, used to compare against
  #   default category names as the family sees them
  def initialize(user_categories = [], locale: nil)
    @user_categories = user_categories
    @locale = locale
  end

  # mcc is the transaction's Merchant Category Code (Monobank's `mcc` field). Returns a
  # matching Category, or nil when the code is unmapped or has no equivalent among the
  # user's categories.
  def match(mcc)
    group = mcc_group(mcc)
    return nil unless group

    match_group(group)
  end

  private
    attr_reader :user_categories, :locale
end
