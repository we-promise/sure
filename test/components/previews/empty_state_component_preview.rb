class EmptyStateComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[480px]
  def default
    render DS::EmptyState.new(
      icon: "inbox",
      title: "No transactions yet",
      description: "Imported and synced transactions will show up here."
    )
  end

  # @display container_classes max-w-[480px]
  def with_action
    render DS::EmptyState.new(
      icon: "repeat",
      title: "No recurring transactions",
      description: "We detect patterns automatically, or you can scan now."
    ) do |es|
      es.with_action do
        render DS::Link.new(text: "Scan now", icon: "search", variant: "primary", href: "#")
      end
    end
  end
end
