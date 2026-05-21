class DS::Disclosure < DesignSystemComponent
  renders_one :summary_content

  VARIANTS = %i[default card card_inset].freeze

  attr_reader :title, :align, :open, :variant, :opts

  # `:default` — bg-surface summary, no chrome on the `<details>`. Use
  # for inline expanders inside a parent card.
  #
  # `:card` — `<details>` itself becomes a `bg-container shadow-border-xs
  # rounded-xl` card; the summary inherits the container (no own bg).
  # Use for provider-item rows (binance, lunchflow, plaid, etc.) where
  # each card is the surface and the summary is custom rich content.
  #
  # `:card_inset` — `<details>` is `bg-surface-inset rounded-xl` (no
  # shadow). Use for inset sub-panels inside a parent card surface
  # (e.g. the IBKR flex-query "report details" panel embedded inside
  # the IBKR settings flow). Same summary contract as `:card`.
  #
  # In both card variants, callers should pass their own
  # `summary_content` slot; the built-in title rendering assumes the
  # `:default` shape.
  def initialize(title: nil, align: "right", open: false, variant: :default, **opts)
    @title = title
    @align = align.to_sym
    @open = open
    @variant = variant.to_sym
    @opts = opts

    raise ArgumentError, "Invalid variant: #{@variant}. Must be one of #{VARIANTS.inspect}" unless VARIANTS.include?(@variant)
  end

  def details_classes
    base = case variant
    when :card
      "group bg-container p-4 shadow-border-xs rounded-xl"
    when :card_inset
      "group bg-surface-inset rounded-xl p-4"
    else
      "group"
    end

    class_names(base, opts[:class])
  end

  # `opts` minus the `:class` key, since `details_classes` merges that
  # separately to avoid duplicate-keyword collisions when forwarding to
  # `tag.details`.
  def details_opts
    opts.except(:class)
  end

  def summary_classes
    case variant
    when :card, :card_inset
      # Card variants: no bg on summary — the parent details *is* the
      # surface. Keep cursor + focus-visible ring + flex baseline.
      # Ring token matches `settings/provider_card.html.erb` (the
      # established focus pattern on container cards).
      "list-none cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-alpha-black-300 rounded-xl"
    else
      "px-3 py-2 rounded-xl cursor-pointer flex items-center justify-between bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-alpha-black-300"
    end
  end
end
