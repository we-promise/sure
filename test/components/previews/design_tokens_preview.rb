class DesignTokensPreview < ViewComponent::Preview
  # Each section is its own preview so the Lookbook nav groups them.
  # Source of truth: design/tokens/sure.tokens.json.
  #
  # All values are pre-resolved in this class (refs and {ref|N%} expanded to
  # final hex / rgba strings) so templates iterate over plain data with no
  # Tailwind-runtime dependency.

  TAILWIND_TEXT_SIZES = [
    [ "text-xs",   "12px / 16px" ],
    [ "text-sm",   "14px / 20px" ],
    [ "text-base", "16px / 24px" ],
    [ "text-lg",   "18px / 28px" ],
    [ "text-xl",   "20px / 28px" ],
    [ "text-2xl",  "24px / 32px" ],
    [ "text-3xl",  "30px / 36px" ],
    [ "text-4xl",  "36px / 40px" ],
    [ "text-5xl",  "48px" ]
  ].freeze

  TAILWIND_FONT_WEIGHTS = [
    [ "font-light",     300 ],
    [ "font-normal",    400 ],
    [ "font-medium",    500 ],
    [ "font-semibold",  600 ],
    [ "font-bold",      700 ]
  ].freeze

  def typography
    render_with_template(locals: {
      fonts: collect_fonts,
      text_sizes: TAILWIND_TEXT_SIZES,
      font_weights: TAILWIND_FONT_WEIGHTS
    })
  end

  def palette
    render_with_template(locals: {
      base_colors: collect_named_colors(%w[white black]),
      semantic_colors: collect_named_colors(%w[success warning destructive shadow]),
      budget_colors: collect_budget,
      scales: collect_scales
    })
  end

  def surfaces
    render_with_template(locals: { utilities: collect_utilities { |name| name.start_with?("bg-") } })
  end

  def text
    render_with_template(locals: { utilities: collect_utilities { |name| name.start_with?("text-") } })
  end

  def borders
    render_with_template(locals: { utilities: collect_utilities { |name| name.start_with?("border-") || name.start_with?("shadow-border-") } })
  end

  def controls
    render_with_template(locals: { utilities: collect_utilities { |name| name.start_with?("button-bg-") || name.start_with?("tab-") || name == "bg-nav-indicator" } })
  end

  def effects
    render_with_template(locals: {
      shadows: collect_shadows,
      radii: collect_radii
    })
  end

  private

    # ─── Data builders ──────────────────────────────────────────────────────

    def collect_fonts
      walked.select { |path, _| path.first == "font" }.map do |path, node|
        { var: var_name(path), name: path.last, value: node["$value"] }
      end
    end

    def collect_named_colors(names)
      walked.filter_map do |path, node|
        next unless path.first == "color" && path.length == 2 && names.include?(path[1])
        build_color_entry(path, node)
      end
    end

    def collect_budget
      walked.filter_map do |path, node|
        next unless path.first == "budget"
        build_color_entry(path, node)
      end
    end

    def collect_scales
      scales = {}
      walked.each do |path, node|
        next unless path.first == "color" && path.length > 2
        scales[path[1]] ||= []
        scales[path[1]] << build_color_entry(path, node)
      end
      scales
    end

    def collect_utilities
      walked.filter_map do |path, node|
        next unless path.first == "utility"
        name = path[1]
        next unless yield(name)
        ext = node["$extensions"] || {}
        light_raw = node["$value"]
        dark_raw = ext["sure.dark"]
        {
          name: path[1..].join("-"),
          light_value: light_raw,
          dark_value: dark_raw,
          light_resolved: light_raw.is_a?(String) ? resolve_template(light_raw) : nil,
          dark_resolved:  dark_raw.is_a?(String) ? resolve_template(dark_raw) : nil,
          compose: ext["sure.compose"]
        }
      end
    end

    def collect_shadows
      walked.filter_map do |path, node|
        next unless path.first == "shadow"
        {
          var: var_name(path),
          name: path.last,
          light_resolved: resolve_value(node),
          light_raw: node["$value"],
          dark_raw: node.dig("$extensions", "sure.dark")
        }
      end
    end

    def collect_radii
      walked.filter_map do |path, node|
        next unless path.first == "border" && path.length == 3
        { var: var_name(path), name: path.last, value: resolve_value(node) || node["$value"] }
      end
    end

    def build_color_entry(path, node)
      {
        var: var_name(path),
        name: path.last,
        light_resolved: resolve_value(node) || node["$value"],
        light_raw: node["$value"],
        dark_resolved: resolve_dark(node),
        dark_raw: node.dig("$extensions", "sure.dark")
      }
    end

    # ─── Token walker ───────────────────────────────────────────────────────

    def tokens
      @tokens ||= JSON.parse(Rails.root.join("design/tokens/sure.tokens.json").read)
    end

    def walked
      @walked ||= begin
        result = []
        walker = lambda do |node, path|
          return unless node.is_a?(Hash)
          if node.key?("$value") || node["$type"] == "utility"
            result << [ path, node ]
            return unless node["$value"].is_a?(Hash)
          end
          node.each do |k, v|
            next if k.start_with?("$")
            walker.call(v, path + [ k ])
          end
        end
        walker.call(tokens, [])
        result
      end
    end

    # ─── Reference resolution ───────────────────────────────────────────────

    def var_name(path)
      cleaned = path.last == "DEFAULT" ? path[0..-2] : path
      "--#{cleaned.join('-')}"
    end

    def resolve_value(node)
      return nil unless node.is_a?(Hash)
      v = node["$value"]
      return nil unless v.is_a?(String)
      resolve_template(v)
    end

    def resolve_dark(node)
      raw = node.dig("$extensions", "sure.dark")
      raw ? resolve_template(raw) : nil
    end

    def resolve_template(str)
      str.gsub(/\{([^|}]+)(?:\|([^}]+))?\}/) do
        ref_path = Regexp.last_match(1).split(".")
        alpha = Regexp.last_match(2)
        target = lookup(ref_path)
        resolved = target ? (resolve_value(target) || target["$value"]) : Regexp.last_match(0)
        alpha ? hex_to_rgba(resolved, alpha) : resolved
      end
    end

    def lookup(path)
      path.inject(tokens) { |h, k| h.is_a?(Hash) ? h[k] : nil }
    end

    def hex_to_rgba(hex, percent_str)
      return hex unless hex.is_a?(String) && hex.start_with?("#")
      h = hex.delete_prefix("#")
      h = h.chars.map { |c| c * 2 }.join if h.length == 3
      r, g, b = h[0, 2].to_i(16), h[2, 2].to_i(16), h[4, 2].to_i(16)
      pct = percent_str.to_s.delete("%").to_f / 100.0
      "rgba(#{r}, #{g}, #{b}, #{pct.round(3)})"
    end
end
