class DS::Disclosure < DesignSystemComponent
  renders_one :summary_content

  VARIANTS = %i[default card].freeze

  attr_reader :title, :align, :open, :variant, :opts

  # `:default` — bg-surface summary, no chrome on the `<details>`. Use
  # for inline expanders inside a parent card.
  #
  # `:card` — `<details>` itself becomes a `bg-container shadow-border-xs
  # rounded-xl` card; the summary inherits the container (no own bg).
  # Use for provider-item rows (binance, lunchflow, plaid, etc.) where
  # each card is the surface and the summary is custom rich content.
  # Callers in `:card` mode should pass their own `summary_content`
  # slot; the built-in title rendering assumes the `:default` shape.
  def initialize(title: nil, align: "right", open: false, variant: :default, **opts)
    @title = title
    @align = align.to_sym
    @open = open
    @variant = variant.to_sym
    @opts = opts

    raise ArgumentError, "Invalid variant: #{@variant}. Must be one of #{VARIANTS.inspect}" unless VARIANTS.include?(@variant)
  end

  def details_classes
    case variant
    when :card
      "group bg-container p-4 shadow-border-xs rounded-xl"
    else
      "group"
    end
  end

  def summary_classes
    case variant
    when :card
      # Card variant: no bg on summary — the parent details *is* the
      # surface. Keep cursor + focus-visible ring + flex baseline.
      "list-none cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gray-900 theme-dark:focus-visible:outline-white"
    else
      "px-3 py-2 rounded-xl cursor-pointer flex items-center justify-between bg-surface focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gray-900 theme-dark:focus-visible:outline-white"
    end
  end
end
