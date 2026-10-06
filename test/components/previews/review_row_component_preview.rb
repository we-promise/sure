class ReviewRowComponentPreview < ViewComponent::Preview
  # Below @md the buttons drop under the text; resize to see the row reflow.
  # @display container_classes max-w-[640px]
  def default
    render DS::ReviewRow.new do |row|
      row.with_actions do
        safe_join([
          render(DS::Button.new(text: "Confirm", variant: "primary")),
          render(DS::Button.new(text: "Dismiss", variant: "ghost"))
        ])
      end
      content_tag(:p, "VERIZON WIRELESS looks like a payment of Verizon", class: "text-sm text-primary @md:truncate")
    end
  end

  # An unspaced descriptor breaks instead of pushing past the card.
  # @display container_classes max-w-[320px]
  def unspaced_descriptor
    render DS::ReviewRow.new do |row|
      row.with_actions { render(DS::Button.new(text: "Confirm", variant: "primary")) }
      content_tag(:p, "POS-PURCHASE-VERIZONWIRELESS-AUTOPAY-REF1234567890", class: "text-sm text-primary @md:truncate")
    end
  end
end
