class DS::MenuItem < DesignSystemComponent
  VARIANTS = %i[link button divider].freeze

  attr_reader :variant, :text, :icon, :href, :method, :destructive, :confirm, :frame, :roving, :opts

  # `roving: true` (default) emits `tabindex="-1"` and `role="menuitem"` — correct
  # for `DS::Menu`, which provides arrow-key roving and announces `role="menu"`.
  # `roving: false` omits both so items stay in the normal Tab order — required
  # inside `DS::Popover`, which has no roving handler and is not a `role="menu"`
  # container.
  def initialize(variant:, text: nil, icon: nil, href: nil, method: :post, destructive: false, confirm: nil, frame: nil, roving: true, **opts)
    @variant = variant.to_sym
    @text = text
    @icon = icon
    @href = href
    @method = method.to_sym
    @destructive = destructive
    @confirm = confirm
    @frame = frame
    @roving = roving
    @opts = opts
    raise ArgumentError, "Invalid variant: #{@variant}" unless VARIANTS.include?(@variant)
  end

  def wrapper(&block)
    # When roving is on, `menuitem_attrs` is part of the `DS::Menu` ARIA contract
    # and must win — strip any caller overrides of `role`/`tabindex` from
    # `merged_opts` before splatting, so a stray `role: :button` or
    # `tabindex: 0` can't downgrade keyboard/AT semantics.
    html_opts = roving ? merged_opts.except(:role, :tabindex) : merged_opts

    if variant == :button
      button_to href, method: method, class: container_classes, **html_opts, **menuitem_attrs, &block
    elsif variant == :link
      link_to href, class: container_classes, **html_opts, **menuitem_attrs, &block
    else
      nil
    end
  end

  def text_classes
    [
      "text-sm",
      destructive? ? "text-destructive" : "text-primary"
    ].join(" ")
  end

  def destructive?
    method == :delete || destructive
  end

  private
    def menuitem_attrs
      roving ? { role: "menuitem", tabindex: "-1" } : {}
    end

    def container_classes
      [
        "flex items-center gap-2 p-2 rounded-md w-full",
        destructive? ? "hover:bg-red-tint-5 theme-dark:hover:bg-red-tint-10" : "hover:bg-container-hover"
      ].join(" ")
    end

    def merged_opts
      merged_opts = opts.dup || {}
      data = merged_opts.delete(:data) || {}

      if confirm.present?
        confirm_value = confirm.respond_to?(:to_data_attribute) ? confirm.to_data_attribute : confirm
        data = data.merge(turbo_confirm: confirm_value)
      end

      if frame.present?
        data = data.merge(turbo_frame: frame)
      end

      merged_opts.merge(data: data)
    end
end
