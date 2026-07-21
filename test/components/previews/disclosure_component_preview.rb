class DisclosureComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[400px]
  # @param align select ["left", "right"]
  def default(align: "right")
    render DS::Disclosure.new(title: "Title", align: align, open: true) do |disclosure|
      disclosure.with_summary_content do
        content_tag(:p, "$200.25", class: "text-xs font-mono font-medium")
      end

      content_tag(:p, "Sample disclosure content", class: "text-sm")
    end
  end

  # @display container_classes max-w-[400px]
  def bare
    render DS::Disclosure.new(variant: :bare, open: true, summary_class: "cursor-pointer") do |disclosure|
      disclosure.with_summary_content do
        content_tag(:span, "Edit", class: "text-sm")
      end

      content_tag(:p, "Absolutely positioned panels should use the bare variant.", class: "text-sm absolute mt-2")
    end
  end
end
