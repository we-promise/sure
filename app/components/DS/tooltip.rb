class DS::Tooltip < ApplicationComponent
  AS_OPTIONS = %i[button span].freeze

  attr_reader :placement, :offset, :cross_axis, :icon_name, :size, :color, :tooltip_id, :as, :html_class

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
  def initialize(text: nil, placement: "top", offset: 10, cross_axis: 0, icon: "info", size: "sm", color: "default", as: :button, html_class: nil)
    raise ArgumentError, "as: must be one of #{AS_OPTIONS.inspect}" unless AS_OPTIONS.include?(as)

    @text = text
    @placement = placement
    @offset = offset
    @cross_axis = cross_axis
    @icon_name = icon
    @size = size
    @color = color
    @as = as
    @html_class = html_class
    @tooltip_id = "tooltip-#{SecureRandom.hex(4)}"
  end

  def tooltip_content
    content? ? content : @text
  end
end
