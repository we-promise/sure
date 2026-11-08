class DS::Card < DesignSystemComponent
  attr_reader :opts

  # Generic bordered surface panel: bg-container + rounded-xl + shadow-border-xs.
  # Extracted from the Plan hub's budget/goals cards, which had this exact
  # shell hand-rolled twice (#2687 review) — reach for this instead of
  # repeating the class string for the next card-shaped panel.
  #
  # Pass padding: to replace the default p-5; smaller paddings (e.g. p-4)
  # cannot win via opts[:class] because p-5 comes later in the compiled CSS.
  def initialize(padding: "p-5", **opts)
    @padding = padding
    @opts = opts
  end

  def container_classes
    class_names("bg-container rounded-xl shadow-border-xs flex flex-col", @padding, opts[:class])
  end

  def container_opts
    opts.except(:class)
  end
end
