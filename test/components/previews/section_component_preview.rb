class SectionComponentPreview < ViewComponent::Preview
  BILLS = [ "Rent", "Streaming", "Car insurance" ].freeze

  # @display container_classes max-w-[640px]
  def default
    render DS::Section.new(title: "This month", count: BILLS.size) do |section|
      section.with_aside { content_tag(:p, "$1,927.29 due", class: "text-xs text-secondary") }
      rows
    end
  end

  # A list that can run long folds away under its heading. Pass persist_key to
  # keep it folded across reloads.
  # @display container_classes max-w-[640px]
  def collapsible
    render DS::Section.new(title: "Possible new bills", count: BILLS.size, collapsible: true) do |section|
      section.with_aside { content_tag(:p, "Tap to review", class: "text-xs text-subdued group-open:hidden") }
      rows
    end
  end

  private
    def rows
      safe_join(BILLS.map { |name| content_tag(:p, name, class: "px-4 py-3 text-sm text-primary") })
    end
end
