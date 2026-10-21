class DetailRowComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[400px]
  # @param align select ["start", "center", "baseline"]
  # @param truncate toggle
  def default(align: "start", truncate: false)
    render DS::DetailRow.new(
      label: "Original description",
      value: "TARGET 00023 SAN MATEO CA",
      align: align.to_sym,
      truncate: truncate
    )
  end

  # Long values wrap rather than being clipped, so a provider's full description
  # stays readable instead of hiding behind a title attribute.
  # @display container_classes max-w-[400px]
  def wrapping
    render DS::DetailRow.new(
      label: "Counterparty 1 · name",
      value: "A deliberately long counterparty name that has to wrap onto more than one line"
    )
  end

  # @display container_classes max-w-[400px]
  def with_value_slot
    render DS::DetailRow.new(label: "Merchant") do |row|
      row.with_value { content_tag(:span, "Whole Foods", class: "font-medium") }
    end
  end

  # @!group In a list
  # @display container_classes max-w-[400px]
  def grouped
    render_with_template(template: "detail_row_component_preview/grouped")
  end
  # @!endgroup
end
