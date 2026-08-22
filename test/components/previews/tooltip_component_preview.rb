class TooltipComponentPreview < ViewComponent::Preview
  # @param text text
  # @param placement select [top, right, bottom, left]
  # @param offset number
  # @param cross_axis number
  # @param icon text
  # @param size select [xs, sm, md, lg, xl, 2xl]
  # @param color select [default, white, success, warning, destructive, current]
  # @param as select [button, span]
  def default(text: "This is helpful information", placement: "top", offset: 10, cross_axis: 0, icon: "info", size: "sm", color: "default", as: "button")
    render DS::Tooltip.new(
      text: text,
      placement: placement,
      offset: offset,
      cross_axis: cross_axis,
      icon: icon,
      size: size,
      color: color,
      as: as.to_sym
    )
  end

  def with_block_content
    render DS::Tooltip.new(icon: "help-circle", color: "warning") do
      tag.div do
        tag.p("Custom content with formatting:", class: "font-medium mb-1") +
        tag.ul(class: "list-disc list-inside text-xs") do
          tag.li("First item") +
          tag.li("Second item")
        end
      end
    end
  end

  # Demonstrates a custom (non-icon) trigger, e.g. underlined text that
  # explains itself further on hover/focus.
  def with_custom_trigger
    render DS::Tooltip.new(text: "$45.00 – $60.00", as: :span) do |tooltip|
      tooltip.with_trigger do
        tag.span("~$52.50", class: "border-b border-dashed border-subdued")
      end
    end
  end
end
