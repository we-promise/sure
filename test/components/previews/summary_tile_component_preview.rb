class SummaryTileComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[320px]
  def default
    render DS::SummaryTile.new(label: "Available net worth") do
      tag.p("$12,400.00", class: "text-2xl font-semibold text-primary")
    end
  end
end
