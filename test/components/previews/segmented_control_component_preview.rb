class SegmentedControlComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[480px]
  # @param full_width toggle
  def default(full_width: true)
    render DS::SegmentedControl.new(full_width: full_width, aria_label: "Budget filter") do |sc|
      sc.with_segment("All", active: true)
      sc.with_segment("Over Budget")
      sc.with_segment("On Track")
    end
  end

  # Link segments (server-selected mode switch, e.g. the auth sign-in/up tabs).
  # @display container_classes max-w-[320px]
  def links
    render DS::SegmentedControl.new(full_width: true, aria_label: "Auth mode") do |sc|
      sc.with_segment("Sign in", href: "#", active: true)
      sc.with_segment("Sign up", href: "#")
    end
  end
end
