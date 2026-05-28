class DS::Tooltip < ApplicationComponent
  AS_OPTIONS = %i[button span].freeze

  attr_reader :placement, :offset, :cross_axis, :icon_name, :size, :color, :tooltip_id, :as

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
  #     sits inside an already-focusable interactive ancestor (most
  #     commonly `<summary>`, where the HTML spec forbids nested
  #     interactive content). The ancestor's focus still triggers the
  #     tooltip because `focusin` bubbles up to the Stimulus controller.
  def initialize(text: nil, placement: "top", offset: 10, cross_axis: 0, icon: "info", size: "sm", color: "default", as: :button)
    raise ArgumentError, "as: must be one of #{AS_OPTIONS.inspect}" unless AS_OPTIONS.include?(as)

    @text = text
    @placement = placement
    @offset = offset
    @cross_axis = cross_axis
    @icon_name = icon
    @size = size
    @color = color
    @as = as
    @tooltip_id = "tooltip-#{SecureRandom.hex(4)}"
  end

  def tooltip_content
    content? ? content : @text
  end
end
