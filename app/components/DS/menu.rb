# frozen_string_literal: true

# `DS::Menu` is a strict action-list primitive. Children are `DS::MenuItem`
# (link / button / divider) only; the container announces as `role="menu"`,
# items as `role="menuitem"`, dividers as `role="separator"`. Arrow Up/Down
# and Home/End move focus across items (roving tabindex). Use **only** for
# flat clickable-action lists.
#
# Need a panel that hosts forms, pickers, headings, or user-account
# content? Use `DS::Popover` — `role="menu"` restricts AT users to
# menuitem-only navigation and breaks anything that isn't an action.
class DS::Menu < DesignSystemComponent
  attr_reader :variant, :placement, :offset, :icon_vertical, :no_padding, :testid, :mobile_fullwidth, :max_width, :max_height, :menu_id

  renders_one :button, ->(**button_options, &block) do
    options_with_target = button_options.deep_dup
    options_with_target[:data] = (options_with_target[:data] || {}).merge(DS__menu_target: "button")
    options_with_target[:aria] = (options_with_target[:aria] || {}).merge(
      haspopup: "menu",
      expanded: "false",
      controls: menu_id
    )

    if block
      options_with_target[:type] ||= "button"
      content_tag(:button, **options_with_target, &block)
    else
      DS::Button.new(**options_with_target)
    end
  end

  renders_many :items, DS::MenuItem

  VARIANTS = %i[icon icon_sm button].freeze

  def initialize(variant: "icon", placement: "bottom-end", offset: 12, icon_vertical: false, no_padding: false, testid: nil, mobile_fullwidth: true, max_width: nil, max_height: nil)
    @variant = variant.to_sym
    @placement = placement
    @offset = offset
    @icon_vertical = icon_vertical
    @no_padding = no_padding
    @testid = testid
    @mobile_fullwidth = mobile_fullwidth
    @max_width = max_width
    @max_height = max_height
    @menu_id = "menu-#{SecureRandom.hex(4)}"

    raise ArgumentError, "Invalid variant: #{@variant}. DS::Menu is for action lists only; use DS::Popover for mixed content (forms, pickers, account dropdowns)." unless VARIANTS.include?(@variant)
  end

  # `:icon_sm` renders the dropdown trigger as a 32x32 icon button (DS::Button
  # `size: :sm`) instead of the default 44x44 `:md`. Use for action menus
  # embedded in dense lists (e.g. the category dropdown row trigger) where the
  # 44x44 enhanced-touch-target trigger introduced in #1840 makes every row
  # ~8px taller and the cumulative list height regresses visibly.
  #
  # Trade-off: the `sm` icon button is 32x32, which meets WCAG 2.5.8 AA
  # (24x24) but not 2.5.5 AAA enhanced (44x44). Acceptable for compact
  # dropdown rows that aren't primary touch surfaces; do not use on
  # standalone toolbar / row-action triggers where 44x44 should remain.
  def icon_only?
    variant == :icon || variant == :icon_sm
  end

  def icon_button_size
    variant == :icon_sm ? "sm" : "md"
  end
end
