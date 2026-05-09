# Generic, provider-agnostic category matcher.
#
# Each provider supplies a taxonomy module that responds to:
#
#   .resolve(input) -> { aliases: [String, ...], parent_aliases: [String, ...] } | nil
#
# `input` can be any shape the provider chooses (string, hash, array) — the
# taxonomy decides. The matcher does only the user-side fuzzy alias match.
#
# Adding a new provider requires only a taxonomy module with a `.resolve`
# class method. No changes here.
class Provider::CategoryMatcher
  def initialize(user_categories, taxonomy:)
    @taxonomy   = taxonomy
    @normalized = user_categories.map { |c| [ c, normalize(c.name) ] }
  end

  def match(provider_input)
    resolved = @taxonomy.resolve(provider_input)
    return nil unless resolved

    find_by_aliases(resolved[:aliases]) || find_by_aliases(resolved[:parent_aliases])
  end

  private
    def find_by_aliases(aliases)
      return nil if aliases.blank?
      normalized_aliases = aliases.map { |a| normalize(a) }
      pair = @normalized.find { |_, name| normalized_aliases.any? { |a| matches?(name, a) } }
      pair&.first
    end

    def matches?(name, aliased)
      return true if name == aliased
      return true if name.singularize == aliased || aliased.singularize == name
      # \band\b avoids stripping "and" inside words: "andover", "hand", "land".
      name.gsub(/\band\b|&|\s+/, "") == aliased.gsub(/\band\b|&|\s+/, "")
    end

    def normalize(str)
      str.to_s.downcase.gsub(/[^a-z0-9]/, " ").strip.squeeze(" ")
    end
end
