class DS::SelectableCardPreview < ViewComponent::Preview
  # @param checked toggle
  def default(checked: true)
    render DS::SelectableCard.new(
      name: "bucket[account_ids][]",
      value: "abc",
      title: "Vanguard FTSE All-World (VWCE)",
      subtitle: "ETF",
      amount: "$115,000",
      checked: checked
    )
  end
end
