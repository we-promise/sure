class DS::Pill < DesignSystemComponent
  TONES = %i[violet indigo fuchsia amber green gray].freeze
  STYLES = %i[soft filled outline].freeze
  SIZES = %i[sm md].freeze

  attr_reader :label, :tone, :style, :size, :show_dot, :dot_only, :title, :icon

  # Generic inline pill primitive. Used for Beta / Canary markers and goal
  # status badges, but designed so any future tag (NEW, PRO, EXPERIMENTAL,
  # etc.) reuses the same shape without forking.
  #
  # - `dot_only: true` renders only the colored dot (no label, no border).
  #   Use on the collapsed sidebar nav, where there's no room for the label.
  # - `icon:` overrides the dot with a Lucide icon (sized xs, current color).
  #   Useful for status pills that benefit from a glyph (circle-check,
  #   triangle-alert, pause, etc.) rather than the generic dot.
  # - Sure has full violet / indigo / fuchsia / amber / green / gray ramps
  #   in the design system; this component picks named tokens at render
  #   time. No raw hex.
  def initialize(label: nil, tone: :violet, style: :soft, size: :sm, show_dot: true, dot_only: false, title: nil, icon: nil)
    @label = label || I18n.t("ds.pill.default_label", default: "Beta")
    @tone = TONES.include?(tone.to_sym) ? tone.to_sym : :violet
    @style = STYLES.include?(style.to_sym) ? style.to_sym : :soft
    @size = SIZES.include?(size.to_sym) ? size.to_sym : :sm
    @show_dot = show_dot
    @dot_only = dot_only
    @title = title
    @icon = icon
  end

  def palette
    # Light-mode `text` is mixed 30% with black on top of the 700 stop so
    # the 10–11px uppercase label still reads against the very pale 50
    # background. Without the mix the perceptual contrast feels low even
    # though the raw ratio passes WCAG.
    {
      violet:  { bg: "var(--color-violet-50)",  bg_dark: "var(--color-violet-tint-10)",  text: "color-mix(in oklab, var(--color-violet-700), black 30%)",  text_dark: "var(--color-violet-200)",  border: "var(--color-violet-200)",  dot: "var(--color-violet-500)",  fill: "var(--color-violet-500)" },
      indigo:  { bg: "var(--color-indigo-50)",  bg_dark: "var(--color-indigo-tint-10)",  text: "color-mix(in oklab, var(--color-indigo-700), black 30%)",  text_dark: "var(--color-indigo-200)",  border: "var(--color-indigo-200)",  dot: "var(--color-indigo-500)",  fill: "var(--color-indigo-500)" },
      fuchsia: { bg: "var(--color-fuchsia-50)", bg_dark: "var(--color-fuchsia-tint-10)", text: "color-mix(in oklab, var(--color-fuchsia-700), black 30%)", text_dark: "var(--color-fuchsia-200)", border: "var(--color-fuchsia-200)", dot: "var(--color-fuchsia-500)", fill: "var(--color-fuchsia-500)" },
      amber:   { bg: "var(--color-yellow-50)",  bg_dark: "var(--color-yellow-tint-10)",  text: "color-mix(in oklab, var(--color-yellow-700), black 30%)",  text_dark: "var(--color-yellow-200)",  border: "var(--color-yellow-200)",  dot: "var(--color-yellow-500)",  fill: "var(--color-yellow-500)" },
      green:   { bg: "var(--color-green-50)",   bg_dark: "var(--color-green-tint-10)",   text: "color-mix(in oklab, var(--color-green-700), black 30%)",   text_dark: "var(--color-green-200)",   border: "var(--color-green-200)",   dot: "var(--color-green-500)",   fill: "var(--color-green-500)" },
      gray:    { bg: "var(--color-gray-100)",   bg_dark: "var(--color-gray-tint-10)",    text: "color-mix(in oklab, var(--color-gray-700), black 30%)",    text_dark: "var(--color-gray-200)",    border: "var(--color-gray-200)",    dot: "var(--color-gray-500)",    fill: "var(--color-gray-500)" }
    }[tone]
  end

  def dot_size_px
    size == :md ? 6 : 5
  end

  def container_styles
    p = palette
    case style
    when :filled
      <<~CSS.strip.gsub(/\s+/, " ")
        background-color: #{p[:fill]};
        color: var(--color-white);
        border-color: transparent;
      CSS
    when :outline
      <<~CSS.strip.gsub(/\s+/, " ")
        background-color: transparent;
        color: light-dark(#{p[:text]}, #{p[:text_dark]});
        border-color: light-dark(#{p[:border]}, color-mix(in oklab, #{p[:dot]} 40%, transparent));
      CSS
    else # :soft
      <<~CSS.strip.gsub(/\s+/, " ")
        background-color: light-dark(#{p[:bg]}, #{p[:bg_dark]});
        color: light-dark(#{p[:text]}, #{p[:text_dark]});
        border-color: light-dark(#{p[:border]}, color-mix(in oklab, #{p[:dot]} 20%, transparent));
      CSS
    end
  end

  def dot_color
    style == :filled ? "rgba(255,255,255,0.85)" : palette[:dot]
  end

  def container_classes
    base = [
      "inline-flex items-center align-middle font-medium uppercase whitespace-nowrap shrink-0",
      "border rounded-md",
      "leading-none"
    ]
    # text-[10/11px] stays as arbitrary values: the pill is intentionally
    # sub-12px (Sure's smallest scale token is text-xs / 12px) to read as
    # a marker, not a label. Padding / gap / tracking snap to Tailwind's
    # scale to satisfy the design-system "no arbitrary values" rule.
    base << (size == :md ? "px-2 py-0.5 text-[11px] tracking-wide gap-1" : "px-1.5 py-0.5 text-[10px] tracking-wider gap-1")
    class_names(*base)
  end
end
