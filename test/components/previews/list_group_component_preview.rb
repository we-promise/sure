class ListGroupComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[480px]
  # @param level select ["outer", "inner", "tight"]
  def default(level: "inner")
    render DS::ListGroup.new(level: level) do
      safe_join(
        [ "First item", "Second item", "Third item" ].map do |label|
          content_tag(:div, label, class: "p-3 text-sm text-primary")
        end
      )
    end
  end
end
