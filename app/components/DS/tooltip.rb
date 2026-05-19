class DS::Tooltip < ApplicationComponent
  attr_reader :placement, :offset, :cross_axis, :icon_name, :size, :color, :tooltip_id

  # NOTE: tooltip content must be non-interactive — no buttons, links,
  # or form controls inside. Tooltips are exposed via `aria-describedby`,
  # which announces the content as a description but does not expose
  # interactive descendants to AT. Use a popover/menu primitive when
  # the surface needs to host actions.
  def initialize(text: nil, placement: "top", offset: 10, cross_axis: 0, icon: "info", size: "sm", color: "default")
    @text = text
    @placement = placement
    @offset = offset
    @cross_axis = cross_axis
    @icon_name = icon
    @size = size
    @color = color
    @tooltip_id = "tooltip-#{SecureRandom.hex(4)}"
  end

  def tooltip_content
    content? ? content : @text
  end
end
