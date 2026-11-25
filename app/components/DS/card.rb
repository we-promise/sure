class DS::Card < DesignSystemComponent
  attr_reader :opts, :variant, :tag_name

  VARIANTS = {
    # Generic bordered surface panel. Extracted from the Plan hub's
    # budget/goals cards, which had this exact shell hand-rolled twice
    # (#2687 review) — reach for this instead of repeating the class string
    # for the next card-shaped panel.
    default: "bg-container rounded-xl shadow-border-xs p-5 flex flex-col",
    # A panel set into another surface, such as a form or QR code opened
    # below a connection row.
    inset: "bg-container-inset rounded-lg border border-secondary p-4"
  }.freeze

  def initialize(variant: :default, tag: :section, **opts)
    @variant = variant.to_sym
    @tag_name = tag
    @opts = opts
  end

  def container_classes
    class_names(VARIANTS.fetch(variant), opts[:class])
  end

  def container_opts
    opts.except(:class)
  end
end
