class EmptyStateComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[640px]
  # @param variant select ["card", "plain"]
  # @param size select ["sm", "md", "lg"]
  # @param icon_style select ["plain", "filled"]
  # @param with_icon toggle
  # @param with_description toggle
  # @param with_actions toggle
  def default(variant: "card", size: "md", icon_style: "plain",
              with_icon: true, with_description: true, with_actions: true)
    render DS::EmptyState.new(
      title: "Nothing to show yet",
      description: with_description ? "Add your first item to populate this view." : nil,
      icon: with_icon ? "chart-bar" : nil,
      icon_style: icon_style,
      variant: variant,
      size: size
    ) do
      render(DS::Link.new(text: "New item", href: "#", variant: "primary")) if with_actions
    end
  end

  # @display container_classes max-w-[640px]
  def report_landing
    render DS::EmptyState.new(
      title: "No data to report yet",
      description: "Connect an account or add a transaction to start seeing reports.",
      icon: "chart-bar",
      size: :lg,
      variant: :card
    ) do
      safe_join([
        render(DS::Link.new(text: "Add transaction", href: "#", variant: "primary")),
        render(DS::Link.new(text: "Add account", href: "#", variant: "secondary"))
      ])
    end
  end

  # @display container_classes max-w-[480px]
  def first_goal
    render DS::EmptyState.new(
      title: "Set your first savings goal",
      description: "Track progress against a target balance for any of your accounts.",
      icon: "target",
      icon_style: :filled,
      size: :md,
      variant: :card
    )
  end
end
