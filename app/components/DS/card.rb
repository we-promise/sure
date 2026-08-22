class DS::Card < DesignSystemComponent
  attr_reader :opts

  # Generic bordered surface panel: bg-container + rounded-xl + shadow-border-xs.
  # Extracted from the Plan hub's budget/goals cards, which had this exact
  # shell hand-rolled twice (#2687 review) — reach for this instead of
  # repeating the class string for the next card-shaped panel.
  def initialize(**opts)
    @opts = opts
  end

  def container_classes
    class_names("bg-container rounded-xl shadow-border-xs p-5 flex flex-col", opts[:class])
  end

  def container_opts
    opts.except(:class)
  end
end
