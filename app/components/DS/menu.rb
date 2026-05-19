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
  attr_reader :variant, :placement, :offset, :icon_vertical, :no_padding, :testid, :mobile_fullwidth, :max_width, :menu_id

  renders_one :button, ->(**button_options, &block) do
    options_with_target = button_options.deep_dup
    options_with_target[:data] = (options_with_target[:data] || {}).merge(DS__menu_target: "button")
    options_with_target[:aria] = {
      haspopup: "menu",
      expanded: "false",
      controls: menu_id
    }.merge(options_with_target[:aria] || {})

    if block
      options_with_target[:type] ||= "button"
      content_tag(:button, **options_with_target, &block)
    else
      DS::Button.new(**options_with_target)
    end
  end

  renders_many :items, DS::MenuItem

  VARIANTS = %i[icon button].freeze

  def initialize(variant: "icon", placement: "bottom-end", offset: 12, icon_vertical: false, no_padding: false, testid: nil, mobile_fullwidth: true, max_width: nil)
    @variant = variant.to_sym
    @placement = placement
    @offset = offset
    @icon_vertical = icon_vertical
    @no_padding = no_padding
    @testid = testid
    @mobile_fullwidth = mobile_fullwidth
    @max_width = max_width
    @menu_id = "menu-#{SecureRandom.hex(4)}"

    raise ArgumentError, "Invalid variant: #{@variant}. DS::Menu is for action lists only; use DS::Popover for mixed content (forms, pickers, account dropdowns)." unless VARIANTS.include?(@variant)
  end
end
