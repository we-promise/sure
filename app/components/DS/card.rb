class DS::Card < DesignSystemComponent
  attr_reader :opts

  # Generic bordered surface panel: bg-container + rounded-xl + shadow-border-xs.
  # Extracted from the Plan hub's budget/goals cards, which had this exact
  # shell hand-rolled twice (#2687 review) — reach for this instead of
  # repeating the class string for the next card-shaped panel.
  # `padding:` — `:default` (p-5); `:panel`, the page panels' responsive
  # padding (an account's activity, an institution's accounts); `:none` for
  # a panel whose sections pad themselves (a chart card).
  PADDINGS = { default: "p-5", panel: "px-3 py-4 lg:p-4", none: nil }.freeze

  def initialize(padding: :default, **opts)
    raise ArgumentError, "Invalid padding: #{padding.inspect}. Must be one of #{PADDINGS.keys.inspect}" unless PADDINGS.key?(padding)

    @padding = padding
    @opts = opts
  end

  def container_classes
    class_names("bg-container rounded-xl shadow-border-xs flex flex-col", PADDINGS[@padding], opts[:class])
  end

  def container_opts
    opts.except(:class)
  end
end
