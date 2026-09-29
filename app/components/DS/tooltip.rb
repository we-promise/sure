class DS::Tooltip < ApplicationComponent
  AS_OPTIONS = %i[button span].freeze
  VARIANTS = %i[inverse surface].freeze

  attr_reader :placement, :offset, :cross_axis, :icon_name, :size, :color, :tooltip_id, :as, :html_class, :variant

  # Optional custom trigger that replaces the icon, for hover-to-reveal
  # details on existing markup (e.g. a summary pill). It renders like
  # `as: :span`: pass it only inside an already-focusable ancestor, or on
  # markup that needs no keyboard reveal of its own.
  renders_one :trigger

  # NOTE: tooltip content must be non-interactive — no buttons, links,
  # or form controls inside. Tooltips are exposed via `aria-describedby`,
  # which announces the content as a description but does not expose
  # interactive descendants to AT. Use a popover/menu primitive when
  # the surface needs to host actions.
  #
  # `as:` controls the trigger element.
  #   :button (default) — renders `<button type="button">`, focusable on
  #     its own. Use for tooltips placed in standalone, non-interactive
  #     surrounding markup.
  #   :span — renders `<span>` with no `tabindex`. Use when the tooltip
  #     sits inside an already-focusable interactive ancestor (`<a>`,
  #     `<summary>`, …) where nested interactive content is forbidden or
  #     undesirable. The Stimulus controller also binds focus handlers on
  #     the closest `a`/`summary` ancestor so keyboard focus on that
  #     element reveals the tooltip (`focusin` only bubbles upward).
  #
  # `html_class:` is merged onto the outer controller wrapper. Pass
  # sizing/layout utilities (e.g. `size-full items-center justify-center`)
  # when `as: :span` should fill an icon-only link so hover covers the
  # whole hit target, not just the icon glyph.
  #
  # `variant:` picks the panel surface.
  #   :inverse (default) — dark-on-light hint bubble for short help text.
  #   :surface — themed card matching the chart hover cards
  #     (`.chart-tooltip`), for richer content such as colored pills that
  #     would lose contrast on the inverse surface.
  def initialize(text: nil, placement: "top", offset: 10, cross_axis: 0, icon: "info", size: "sm", color: "default", as: :button, html_class: nil, variant: :inverse)
    raise ArgumentError, "as: must be one of #{AS_OPTIONS.inspect}" unless AS_OPTIONS.include?(as)
    raise ArgumentError, "variant: must be one of #{VARIANTS.inspect}" unless VARIANTS.include?(variant.to_sym)

    @text = text
    @placement = placement
    @offset = offset
    @cross_axis = cross_axis
    @icon_name = icon
    @size = size
    @color = color
    @as = as
    @html_class = html_class
    @variant = variant.to_sym
    @tooltip_id = "tooltip-#{SecureRandom.hex(4)}"
  end

  def panel_classes
    variant == :surface ? "chart-tooltip text-sm" : "bg-inverse text-sm px-1.5 py-1 rounded-md"
  end

  def content_classes
    variant == :surface ? "text-primary font-normal max-w-[20rem]" : "text-inverse font-normal max-w-[20rem]"
  end

  def tooltip_content
    # With a `trigger` slot the block exists to set the slot, so its return
    # value must not shadow `text:`.
    return @text if trigger? && @text.present?

    content? ? content : @text
  end
end
