# frozen_string_literal: true

# `DS::IconPicker` is a shared, searchable lucide-icon grid.
#
# `method` is a parameter because the backing columns can differ:
# for now `categories.lucide_icon` and `goals.icon`.
class DS::IconPicker < DesignSystemComponent
  attr_reader :form, :method, :icons, :placeholder

  def initialize(form:, method:, icons:, placeholder: nil)
    @form = form
    @method = method
    @icons = icons
    @placeholder = placeholder || I18n.t("ds.icon_picker.search_placeholder")
  end
end
