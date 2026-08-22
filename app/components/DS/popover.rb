# frozen_string_literal: true

# `DS::Popover` is a positioned panel for **mixed, non-action-list** content:
# user-account menus, picker forms, filter forms, embedded controls. The
# panel hosts arbitrary markup and **does not** announce as a `role="menu"`
# — that role restricts AT users to menuitem-only navigation, which breaks
# any panel containing form inputs, headings, or generic groupings.
#
# Use `DS::Menu` instead when the panel is a flat list of clickable actions.
class DS::Popover < DesignSystemComponent
  attr_reader :variant, :avatar_url, :initials, :placement, :offset, :icon, :no_padding, :testid, :mobile_fullwidth, :max_width, :panel_id

  renders_one :button, ->(**button_options, &block) do
    options_with_target = button_options.deep_dup
    options_with_target[:data] = (options_with_target[:data] || {}).merge(DS__popover_target: "button")
    options_with_target[:aria] = {
      haspopup: "dialog",
      expanded: "false",
      controls: panel_id
    }.merge(options_with_target[:aria] || {})

    if block
      options_with_target[:type] ||= "button"
      content_tag(:button, **options_with_target, &block)
    else
      DS::Button.new(**options_with_target)
    end
  end

  renders_one :header, ->(&block) do
    content_tag(:div, class: "border-b border-tertiary", &block)
  end

  renders_one :custom_content

  VARIANTS = %i[icon button avatar].freeze

  def initialize(variant: "icon", avatar_url: nil, initials: nil, placement: "bottom-end", offset: 12, icon: "more-horizontal", no_padding: false, testid: nil, mobile_fullwidth: true, max_width: nil, aria_label: nil)
    @variant = variant.to_sym
    @avatar_url = avatar_url
    @initials = initials
    @placement = placement
    @offset = offset
    @icon = icon
    @no_padding = no_padding
    @testid = testid
    @mobile_fullwidth = mobile_fullwidth
    @max_width = max_width
    @aria_label = aria_label
    @panel_id = "popover-#{SecureRandom.hex(4)}"

    raise ArgumentError, "Invalid variant: #{@variant}" unless VARIANTS.include?(@variant)
  end

  # Accessible name for the trigger button. The `:avatar` variant has no
  # visible text, so the caller MUST pass `aria_label:`. `:icon` and
  # `:button` variants fall back to DS::Button's icon-derived label and
  # the slot's own text respectively.
  def trigger_aria_label
    @aria_label || (variant == :avatar ? I18n.t("ds.popover.avatar_default_label", default: "Open menu") : nil)
  end
end
