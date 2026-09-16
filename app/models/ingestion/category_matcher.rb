# Matches normalized candidate hints to existing family categories. Translation
# names precede aliases; no category is created by a provider observation.
class Ingestion::CategoryMatcher
  def initialize(categories, locale:)
    @categories = categories
    @locale = locale
  end

  def match(hints)
    values = hints.with_indifferent_access
    return legacy_ascii_match(values) if values[:normalization] == "legacy_ascii"
    translations = if values[:translation_key].present?
      [ @locale, I18n.default_locale ].compact.map(&:to_s).uniq.filter_map do |locale|
        I18n.t(values[:translation_key], locale: locale, default: nil)
      end
    else
      []
    end
    match_candidates(translations) || match_candidates(Array(values[:aliases]))
  end

  private
    # Plaid historically normalized only user category names, not its taxonomy
    # keys or aliases. Keep that asymmetry and category-order precedence during
    # migration; normalizing both sides would silently reclassify transactions.
    def legacy_ascii_match(values)
      normalized = @categories.map { |category| [ category, category.name.to_s.downcase.gsub(/[^a-z0-9]/, " ").strip ] }
      exact = normalized.find { |_category, name| Array(values[:exact_names]).any? { |candidate| name == candidate.to_s } }
      return exact.first if exact
      [ values[:aliases], values[:fallback_aliases] ].each do |candidates|
        found = normalized.find do |_category, name|
          Array(candidates).any? do |candidate|
            alias_name = candidate.to_s
            name == alias_name || name.singularize == alias_name || name.pluralize == alias_name ||
              alias_name.singularize == name || alias_name.pluralize == name ||
              name.gsub(/(and|&|\s+)/, "").strip == alias_name.gsub(/(and|&|\s+)/, "").strip
          end
        end
        return found.first if found
      end
      nil
    end

    def match_candidates(candidates)
      @categories.find do |category|
        name = normalize(category.name)
        candidates.any? { |candidate| names_match?(name, normalize(candidate)) }
      end
    end

    def names_match?(name, candidate)
      return false if name.blank? || candidate.blank?
      return true if name == candidate || name.singularize == candidate || name.pluralize == candidate ||
        candidate.singularize == name || candidate.pluralize == name
      squash(name) == squash(candidate)
    end

    def normalize(name)
      name.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").strip
    end

    def squash(value)
      value.gsub(/(\band\b|&|\s+)/, "").strip
    end
end
