class InlineEditComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[400px]
  def default
    render_with_template(template: "inline_edit_component_preview/default")
  end
end
