class IconPickerComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[400px]
  def default
    render_with_template(locals: { icons: Category.icon_codes })
  end

  # A short list, to show the "no matching icons" empty state on any
  # search term that isn't one of these.
  # @display container_classes max-w-[400px]
  def few_icons
    render_with_template(template: "icon_picker_component_preview/default", locals: { icons: %w[pizza coffee wrench] })
  end
end
