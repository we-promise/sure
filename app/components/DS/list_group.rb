class DS::ListGroup < DesignSystemComponent
  # A list-group is a Card whose direct children are separated by a single
  # divider line in a token-correct color. Folds together the
  # `bg-container + shadow-border-xs + rounded-* + divide-y + divide-alpha-*`
  # boilerplate that currently lives at every list-group call site in the app
  # (#2135).
  #
  # Item padding lives on the items themselves, not on the container, so
  # default padding here is :none. Pass a `padding:` only when the rare
  # outer card uses uniform inset.

  def initialize(level: :inner, padding: :none, overflow_hidden: true, **html_attrs)
    @level = level
    @padding = padding
    @overflow_hidden = overflow_hidden
    @html_attrs = html_attrs
  end

  def call
    classes = class_names(
      "divide-y divide-alpha-black-100 theme-dark:divide-alpha-white-100",
      @html_attrs.delete(:class)
    )

    render(DS::Card.new(
      level: @level,
      padding: @padding,
      overflow_hidden: @overflow_hidden,
      class: classes,
      **@html_attrs
    )) { content }
  end
end
