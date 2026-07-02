class DS::Disclosure < DesignSystemComponent
  renders_one :summary_content

  VARIANTS = %i[default card card_inset inline].freeze

  attr_reader :title, :align, :open, :variant, :summary_class_override, :body_class, :opts

  # `:default` — bg-surface summary, no chrome on the `<details>`. Use
  # for inline expanders that sit inside a parent card (the summary
  # itself reads as the surface).
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
  # `:inline` — no surface, no padding, no shadow. The disclosure reads
  # as a plain text-link-style toggle (e.g. "Alternative auth" inside
  # a form, or a "Manage connections" lazy-load opener). Caller provides
  # the summary text (and optional chevron) via the `summary_content`
  # slot.
  #
  # In card / inline variants, callers should pass their own
  # `summary_content` slot; the built-in title rendering assumes the
  # `:default` shape.
  # `body_class:` styles the wrapper around the disclosure body. Defaults
  # to `mt-2` (the standard gap below the summary). Pass `nil`/`""` to drop
  # it — e.g. when the body is an absolutely-positioned popover whose
  # wrapper would otherwise add ~8px of normal-flow margin and shove
  # siblings down on open (see `goals/_color_picker`).
  def initialize(title: nil, align: "right", open: false, variant: :default, summary_class: nil, body_class: "mt-2", **opts)
    @title = title
    @align = align.to_sym
    @open = open
    @variant = variant&.to_sym
    @summary_class_override = summary_class
    @body_class = body_class
    @opts = opts

    raise ArgumentError, "Invalid variant: #{@variant.inspect}. Must be one of #{VARIANTS.inspect}" unless VARIANTS.include?(@variant)
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
    return summary_class_override if summary_class_override.present?

    case variant
    when :card, :card_inset
      # Card variants: no bg on summary — the parent details *is* the
      # surface. Keep cursor + focus-visible ring + flex baseline.
      # Ring token matches `settings/provider_card.html.erb` (the
      # established focus pattern on container cards).
      "list-none cursor-pointer focus-ring rounded-xl"
    when :inline
      # Inline variant: no surface, no padding — the summary reads as
      # plain text-link copy. Caller markup (text + optional chevron)
      # provides the visual. Keep cursor + focus-visible ring + matching
      # alpha-black-300 token used by the card variants for consistency.
      "list-none cursor-pointer focus-ring rounded-sm"
    else
      "px-3 py-2 rounded-xl cursor-pointer flex items-center justify-between bg-surface focus-ring min-h-11"
    end
  end
end
