class CardComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[480px] space-y-4
  # @param level select ["outer", "inner", "tight"]
  # @param padding select ["none", "xs", "sm", "md", "lg", "xl"]
  # @param overflow_hidden toggle
  def default(level: "outer", padding: "md", overflow_hidden: false)
    render DS::Card.new(level: level, padding: padding, overflow_hidden: overflow_hidden) do
      content_tag(:p, "Card body content", class: "text-sm text-primary")
    end
  end

  # @display container_classes max-w-[480px]
  def nested
    render DS::Card.new(level: :outer, padding: :lg) do
      content_tag(:div, class: "space-y-4") do
        safe_join([
          content_tag(:h2, "Outer card", class: "text-lg font-medium text-primary"),
          render(DS::Card.new(level: :inner, padding: :md)) do
            content_tag(:p, "Inner card nested inside outer", class: "text-sm text-secondary")
          end
        ])
      end
    end
  end
end
