# frozen_string_literal: true

# `DS::SearchInput` is the standalone search-field primitive — icon on
# the left, bordered container, full token-backed focus ring. Use for
# top-of-list filter inputs (Preferences currency search, Settings/Bank
# Sync provider filter, etc.) that aren't part of a form-field-styled
# `f.search_field` flow and aren't embedded inside another DS panel.
#
# For `form.search_field :foo` inside a styled form, use the form
# helper — it already routes through `StyledFormBuilder`'s field CSS.
# For search inputs *inside* a DS::Select / DS::Menu / DS::Popover panel,
# keep the embedded markup the parent component renders today.
class DS::SearchInput < DesignSystemComponent
  attr_reader :name, :placeholder, :value, :aria_label, :extra_classes, :opts

  def initialize(name: nil, placeholder: nil, value: nil, aria_label: nil, class: nil, **opts)
    @name = name
    @placeholder = placeholder
    @value = value
    @aria_label = aria_label || placeholder
    @extra_classes = binding.local_variable_get(:class)
    @opts = opts
  end

  def container_classes
    class_names("relative", extra_classes)
  end

  def input_classes
    # `focus-visible:outline-*` matches the focus-ring pattern from
    # DS::Button (base.css) so every interactive surface in the design
    # system uses the same ring token. Replaces the broken
    # `focus:ring-gray-500` from the inline callsites — that utility
    # had no backing token and rendered invisibly on the bordered
    # bg-container surface.
    "block w-full border border-secondary rounded-md py-2.5 pl-10 pr-3 bg-container text-sm " \
      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gray-900 " \
      "theme-dark:focus-visible:outline-white"
  end
end
