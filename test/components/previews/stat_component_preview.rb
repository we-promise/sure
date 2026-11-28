class StatComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[400px]
  # @param size select ["lg", "xl"]
  # @param tone select ["primary", "success", "warning"]
  def default(size: "lg", tone: "primary")
    render DS::Stat.new(
      label: "Chance the money lasts",
      value: "94%",
      hint: "Share of 5,000 simulated markets in which the money lasts to the end of the plan.",
      size: size.to_sym,
      tone: tone.to_sym
    )
  end

  # @display container_classes max-w-[400px]
  def without_hint
    render DS::Stat.new(label: "If the worst years come first", value: "35%")
  end

  # A value that is not a single figure goes in the slot.
  # @display container_classes max-w-[400px]
  def with_value_slot
    render DS::Stat.new(label: "Earliest retirement at 90% confidence") do |stat|
      stat.with_value { content_tag(:p, "No retirement year reaches the target before 90.", class: "text-sm text-warning") }
    end
  end
end
