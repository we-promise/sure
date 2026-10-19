# frozen_string_literal: true

# Auto-matches a Redbark transaction's bank-assigned category to one of the family's
# existing Sure categories. Mirrors MonobankAccount::Transactions::CategoryMatcher: a fast,
# cheap, high-confidence pass that never creates categories and never overwrites user data
# (the import adapter applies the result via enrich_attribute, which respects locks). The
# category and MCC tables live in RedbarkAccount::Transactions::CategoryTaxonomy.
#
# `category` (Redbark's fixed bank-category code) is the primary signal: it already
# describes spending purpose, not just merchant type. When it's blank, or one of the codes
# intentionally left unmapped (too coarse/ambiguous to trust), `merchant_category_code`
# (MCC) is tried as a fallback -- a noisier signal, but still better than nothing.
#
# Locale-aware like the Monobank matcher: a Redbark-linked family is not necessarily
# English-speaking, so the family's own locale is tried before the English aliases.
class RedbarkAccount::Transactions::CategoryMatcher
  include RedbarkAccount::Transactions::CategoryTaxonomy

  # @param user_categories [Array<Category>] the family's existing categories
  # @param locale [String, Symbol, nil] the family's locale, used to compare against
  #   default category names as the family sees them
  def initialize(user_categories = [], locale: nil)
    @user_categories = user_categories
    @locale = locale
  end

  # category is the transaction's `category` field (Redbark's fixed bank-category code,
  # e.g. "FOOD_AND_DRINK"). mcc is its `merchant_category_code`, tried only when category
  # has no confident match. Returns a matching Category, or nil when neither signal has an
  # equivalent among the user's categories.
  def match(category, mcc = nil)
    match_group(category_group(category)) || match_group(mcc_group(mcc))
  end

  private
    attr_reader :user_categories, :locale

    def match_group(group)
      return nil unless group

      match_candidates(default_category_names(group[:key])) || match_candidates(group[:aliases])
    end

    # Sure's own name for the default category behind this group, in the family's locale
    # and in the default locale. A family that kept Sure's generated categories matches
    # here regardless of the language they set up in.
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

    # Case- and punctuation-insensitive form. [[:alnum:]] is Unicode-aware in Ruby, so a
    # category named in another script survives normalization instead of being blanked out.
    def normalize_category_name(name)
      name.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").strip
    end
end
