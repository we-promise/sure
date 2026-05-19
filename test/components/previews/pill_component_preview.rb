class PillComponentPreview < ViewComponent::Preview
  # @param tone select ["violet", "indigo", "fuchsia", "amber", "gray"]
  # @param style select ["soft", "filled", "outline"]
  # @param size select ["sm", "md"]
  # @param label text
  # @param show_dot toggle
  # @param dot_only toggle
  def default(tone: "violet", style: "soft", size: "sm", label: "Beta", show_dot: true, dot_only: false)
    render DS::Pill.new(
      label: label,
      tone: tone.to_sym,
      style: style.to_sym,
      size: size.to_sym,
      show_dot: show_dot,
      dot_only: dot_only
    )
  end

  def canary
    render DS::Pill.new(label: "Canary", tone: :fuchsia)
  end

  def dot_only_collapsed_sidebar
    render DS::Pill.new(dot_only: true, tone: :violet)
  end
end
