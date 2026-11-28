# frozen_string_literal: true

# Finds the family's own Category for a taxonomy group, comparing against the category
# names as the family actually sees them.
#
# Shared by the provider matchers whose taxonomy groups carry a `key` (a Sure
# default-category translation key) alongside English `aliases`. Matching the translation
# key first means a family that kept Sure's generated categories matches regardless of the
# language they set up in; the English aliases then cover renamed and hand-made
# categories.
#
# Including classes must provide `user_categories` (the family's categories) and `locale`
# (the family's locale, or nil).
module Transactions::LocaleAwareCategoryMatching
  private
    # The user's Category for a taxonomy group, or nil when they have no equivalent.
    def match_group(group)
      return nil unless group

      match_candidates(default_category_names(group[:key])) || match_candidates(group[:aliases])
    end

    # Sure's own names for the default category behind this group, in every supported
    # locale plus the family and default locales. Defaults can be persisted under a
    # member's locale rather than the family's (CategoriesController#bootstrap uses
    # Current.user.locale), and available locales such as `id` are not in SUPPORTED_LOCALES.
    def default_category_names(key)
      return [] if key.blank?

      @default_category_names ||= {}
      @default_category_names[key] ||= Category.localized_default_names_for(
        "models.category.defaults.#{key}", [ locale, I18n.default_locale ]
      )
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
    # category named in another script (Cyrillic, Greek, CJK) survives normalization
    # instead of being blanked out.
    def normalize_category_name(name)
      name.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").strip
    end
end
