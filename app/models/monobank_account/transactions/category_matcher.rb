# Auto-matches a Monobank transaction's MCC to one of the family's existing Sure
# categories. Mirrors PlaidAccount::Transactions::CategoryMatcher and its Up equivalent:
# a fast, cheap, high-confidence pass that never creates categories and never overwrites
# user data (the import adapter applies the result via enrich_attribute, which respects
# locks). The MCC table lives in MonobankAccount::Transactions::CategoryTaxonomy.
#
# Unlike the Plaid and Up matchers, matching is locale-aware. Those providers hand over
# an English category slug and are matched against English aliases, which quietly
# matches nothing for a family whose categories are named in their own language.
# Monobank's users are Ukrainian by definition, so each MCC group also carries the Sure
# default-category translation key and the family's own locale is tried first.
class MonobankAccount::Transactions::CategoryMatcher
  include MonobankAccount::Transactions::CategoryTaxonomy

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

    match_candidates(default_category_names(group[:key])) || match_candidates(group[:aliases])
  end

  private
    attr_reader :user_categories, :locale

    # Sure's own name for the default category behind this MCC group, in the family's
    # locale and in the default locale. A family that kept Sure's generated categories
    # matches here regardless of the language they set up in.
    def default_category_names(key)
      return [] if key.blank?

      [ locale, I18n.default_locale ].compact.map(&:to_s).uniq.filter_map do |candidate_locale|
        I18n.t("models.category.defaults.#{key}", locale: candidate_locale, default: nil)
      end
    end

    def match_candidates(candidates)
      return nil if candidates.blank?

      hit = normalized_user_categories.find do |category|
        name = category[:name]
        candidates.any? { |candidate| names_match?(name, normalize_category_name(candidate)) }
      end

      hit && user_categories.find { |c| c.id == hit[:id] }
    end

    def names_match?(name, candidate)
      return false if name.blank? || candidate.blank?
      return true if name == candidate
      return true if name.singularize == candidate || name.pluralize == candidate
      return true if candidate.singularize == name || candidate.pluralize == name

      # Strip the standalone "and" conjunction (word-boundaried so it does not eat "and"
      # inside a word, e.g. errand), plus "&" and whitespace, so "Gifts & Donations"
      # matches the alias "gifts and donations".
      squash(name) == squash(candidate)
    end

    def squash(value)
      value.gsub(/(\band\b|&|\s+)/, "").strip
    end

    def normalized_user_categories
      @normalized_user_categories ||= user_categories.map do |user_category|
        { id: user_category.id, name: normalize_category_name(user_category.name) }
      end
    end

    # Case- and punctuation-insensitive form. [[:alnum:]] is Unicode-aware in Ruby, so
    # Cyrillic category names survive normalization instead of being blanked out.
    def normalize_category_name(name)
      name.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").strip
    end
end
