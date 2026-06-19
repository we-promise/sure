# frozen_string_literal: true

# `DS::SearchInput` is the search-field primitive.
#
# Two variants:
#
# - `:standalone` (default) — top-of-list filter inputs (Preferences
#   currency search, Settings/Bank Sync provider filter). Bordered
#   bg-container surface, icon-on-left, full token-backed focus ring.
#
# - `:embedded` — search-inside-a-panel (DS::Select internal search,
#   splits category filter, any future DS::Popover that hosts a filter).
#   No border / no own focus ring — the parent panel provides the
#   chrome, so adding ring + outline here would compete with the
#   parent's focus-within state.
#
# For `form.search_field :foo` inside a `styled_form_with` block,
# keep using the form helper — it routes through `StyledFormBuilder`'s
# form-field CSS, which is a different visual contract.
class DS::SearchInput < DesignSystemComponent
  VARIANTS = %i[standalone embedded].freeze

  attr_reader :variant, :name, :placeholder, :value, :aria_label, :extra_classes, :opts

  def initialize(variant: :standalone, name: nil, placeholder: nil, value: nil, aria_label: nil, class: nil, **opts)
    @variant = variant.to_sym
    @name = name
    @placeholder = placeholder
    @value = value
    @aria_label = aria_label || placeholder
    @extra_classes = binding.local_variable_get(:class)
    @opts = opts

    raise ArgumentError, "Invalid variant: #{@variant}. Must be one of #{VARIANTS.inspect}" unless VARIANTS.include?(@variant)
  end

  def container_classes
    class_names("relative", extra_classes)
  end

  def input_classes
    # `text-base sm:text-sm` — keep the base font at 16px so iOS Safari
    # does not zoom the viewport when the input is focused. Shrink to
    # 14px from `sm:` upward. The previous unconditional `text-sm`
    # triggered the mobile zoom regression.
    case variant
    when :embedded
      # No own focus ring — the parent panel handles focus chrome via
      # `focus-within`. `focus:outline-hidden focus:ring-0` neutralizes
      # the browser default so it doesn't compete with the panel's
      # state.
      "bg-container text-primary text-base sm:text-sm placeholder:text-secondary font-normal " \
        "h-10 pl-10 w-full border-none rounded-lg " \
        "focus:outline-hidden focus:ring-0"
    else
      # Canonical `.focus-ring` (#2136) — one shared keyboard-focus
      # indicator across every DS primitive. Replaces the earlier neutral
      # `outline-gray-900 / theme-dark:outline-white` pair.
      "block w-full border border-secondary rounded-md py-2.5 pl-10 pr-3 bg-container text-base sm:text-sm " \
        "focus-ring"
    end
  end

  def icon_classes
    variant == :embedded ? "absolute inset-0 ml-2 transform top-1/2 -translate-y-1/2" : "text-secondary"
  end

  def icon_wrapper_classes
    # Standalone variant wraps the icon in a positioned div; embedded
    # places the icon as an absolutely-positioned sibling so the parent
    # panel can stay in control of vertical alignment.
    variant == :embedded ? nil : "absolute inset-0 ml-2 top-1/2 -translate-y-1/2 pointer-events-none"
  end
end
