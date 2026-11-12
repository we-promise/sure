# Round 16: the vendored bank-logo catalog. The set of usable logos is the
# INTERSECTION of the vendored files (app/assets/images/bank-logos/<slug>.svg)
# and the label map (config/bank_logo_slugs.yml); the keyword map there
# auto-matches an account name to a slug.
#
# Pure reads: no runtime fetching (owner policy: 100% local), no writes. The
# plan-flow planner receives the same maps as plain inputs (graph_shadow) and
# resolves bank rows itself so the pure-core unit tests cover the resolution
# order (explicit override -> keyword match -> nil).
class BankLogoSlugs
  # App-relative path under app/assets/images (propshaft serves it
  # same-origin; no CSP change).
  LOGO_DIR = "bank-logos".freeze

  class << self
    # { slug => display label } for every slug that has BOTH a vendored SVG
    # file and a label. Sorted by label so the dialog picker is readable.
    def available
      @available ||= begin
        labels.select { |slug, _| logo_file?(slug) }
              .sort_by { |slug, label| label.to_s.downcase }
              .to_h
      end
    end

    # Normalized [keyword, slug] pairs, LONGEST keyword first, restricted to
    # usable slugs. The planner and the resolver both consume this order so
    # "navyfederal" wins over "navy" when both are present.
    def keywords
      @keywords ||= raw_config[:keywords].to_h
                   .select { |keyword, slug| available.key?(slug) }
                   .map { |keyword, slug| [ normalize(keyword), slug ] }
                   .reject { |keyword, _| keyword.blank? }
                   .sort_by { |keyword, _| -keyword.length }
                   .freeze
    end

    # The resolution order the owner specified: an explicit per-account slug
    # (accounts.bank_logo_slug) wins if usable; then the first keyword hit on
    # the account name; otherwise nil (no fabricated logo).
    def resolve(name, explicit: nil)
      explicit = explicit.to_s
      return explicit if explicit.present? && available.key?(explicit)

      keyword_match(name)
    end

    # First (longest-first) keyword substring hit on the normalized name.
    def keyword_match(name)
      normalized = normalize(name)
      return nil if normalized.blank?

      hit = keywords.find { |keyword, _| normalized.include?(keyword) }
      hit && hit.last
    end

    # Lowercase, strip everything non-alphanumeric: "NAVY Vari Bills" ->
    # "navyvaribills". The yml keyword keys are already normalized.
    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end

    def logo_file?(slug)
      logo_dir.join("#{slug}.svg").file?
    end

    private

    def logo_dir
      Rails.root.join("app", "assets", "images", LOGO_DIR)
    end

    def raw_config
      @raw_config ||= begin
        config = Rails.application.config_for("bank_logo_slugs")
        config = {} unless config.is_a?(Hash)
        # config_for deep_symbolizes keys; the DB + payload use STRING slugs,
        # so normalize both maps to string keys (values stay strings).
        {
          labels: stringify_map(config[:labels]),
          keywords: stringify_map(config[:keywords])
        }
      rescue StandardError
        { labels: {}, keywords: {} }
      end
    end

    def labels
      raw_config[:labels]
    end

    def stringify_map(map)
      return {} unless map.is_a?(Hash)

      map.to_h { |key, value| [ key.to_s, value ] }
    end
  end
end
