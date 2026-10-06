class ActionRowComponentPreview < ViewComponent::Preview
  # @param tone select {{ DS::ActionRow::TONES }}
  # @param icon select ["plus", "corner-down-right", "arrow-left", ""]
  def default(tone: :primary, icon: "plus")
    render DS::ActionRow.new(text: 'Create "Groceries"', icon: icon.presence, tone: tone)
  end

  # How rows stack inside a picker: a primary action, a supporting action and a
  # "back" row share the same gutter as the list's own rows.
  def picker_actions
    render_with_template
  end
end
