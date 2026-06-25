# Auto-matches Up Bank's spending categories to the family's existing Sure categories.
# Mirrors PlaidAccount::Transactions::CategoryMatcher: a fast, cheap, high-confidence
# pass that never creates categories and never overwrites user data (the import adapter
# applies the result via enrich_attribute, which respects locks). Up tags a transaction
# with a child category slug (relationships.category.data.id); we map the honest
# equivalents onto Sure's default categories and leave the rest for user rules / AI.
class UpAccount::Transactions::CategoryMatcher
  include UpAccount::Transactions::CategoryTaxonomy

  def initialize(user_categories = [])
    @user_categories = user_categories
  end

  # up_category_slug is the value of relationships.category.data.id, e.g.
  # "restaurants-and-cafes". Returns a matching Category, or nil when the slug is
  # unknown or has no confident equivalent among the user's categories.
  def match(up_category_slug)
    details = category_details(up_category_slug)
    return nil unless details

    # Try an exact match against the slug name first (rare), then the category's own
    # aliases, then its parent group's aliases.
    exact = normalized_user_categories.find { |c| c[:name] == details[:key].to_s }
    return user_categories.find { |c| c.id == exact[:id] } if exact

    match_aliases(details[:aliases]) || match_aliases(details[:parent_aliases])
  end

  private
    attr_reader :user_categories

    def match_aliases(aliases)
      return nil if aliases.blank?

      hit = normalized_user_categories.find do |category|
        name = category[:name]
        aliases.any? do |a|
          alias_str = a.to_s
          next true if name == alias_str
          next true if name.singularize == alias_str || name.pluralize == alias_str
          next true if alias_str.singularize == name || alias_str.pluralize == name

          normalized_name  = name.gsub(/(and|&|\s+)/, "").strip
          normalized_alias = alias_str.gsub(/(and|&|\s+)/, "").strip
          normalized_name == normalized_alias
        end
      end

      hit && user_categories.find { |c| c.id == hit[:id] }
    end

    def category_details(up_category_slug)
      return nil if up_category_slug.blank?

      detailed_categories.find { |c| c[:key] == up_category_slug.to_s.downcase.to_sym }
    end

    def detailed_categories
      @detailed_categories ||= CATEGORIES_MAP.flat_map do |parent_key, parent_data|
        parent_data[:detailed_categories].map do |child_key, child_data|
          {
            key: child_key,
            classification: child_data[:classification],
            aliases: child_data[:aliases],
            parent_key: parent_key,
            parent_aliases: parent_data[:aliases]
          }
        end
      end
    end

    def normalized_user_categories
      @normalized_user_categories ||= user_categories.map do |user_category|
        { id: user_category.id, name: normalize_user_category_name(user_category.name) }
      end
    end

    def normalize_user_category_name(name)
      name.to_s.downcase.gsub(/[^a-z0-9]/, " ").strip
    end
end
