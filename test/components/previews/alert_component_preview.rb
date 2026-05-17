class AlertComponentPreview < Lookbook::Preview
  # @param message text
  # @param title text
  # @param variant select [info, success, warning, error]
  def default(message: "This is an alert message.", title: nil, variant: :info)
    render DS::Alert.new(message: message, title: title.presence, variant: variant.to_sym)
  end

  # @param variant select [info, success, warning, error]
  def with_title(variant: :warning)
    render DS::Alert.new(
      message: "Heads up — this account hasn't synced in 7 days.",
      title: "Stale connection",
      variant: variant.to_sym
    )
  end

  # @param variant select [info, success, warning, error]
  def with_body_slot(variant: :error)
    render DS::Alert.new(title: "We couldn't process this request", variant: variant.to_sym) do
      tag.div do
        safe_join([
          tag.p("Verify the values you submitted and try again. If the issue persists, contact support.", class: "text-secondary"),
          tag.ul(class: "list-disc list-inside text-secondary") do
            safe_join([
              tag.li("Check that all required fields are populated."),
              tag.li("Confirm the dates fall within an open period.")
            ])
          end
        ])
      end
    end
  end
end
