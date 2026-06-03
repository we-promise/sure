# A checkbox rendered as a selectable card: the whole card toggles, with a
# brand-accent border + check glyph when selected. Used for the retirement
# bucket account picker. Submits like a normal checkbox (name[]/value).
class DS::SelectableCard < DesignSystemComponent
  attr_reader :name, :value, :title, :subtitle, :amount, :checked, :opts

  def initialize(name:, value:, title:, subtitle: nil, amount: nil, checked: false, **opts)
    @name = name
    @value = value
    @title = title
    @subtitle = subtitle
    @amount = amount
    @checked = checked
    @opts = opts
  end
end
