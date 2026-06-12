class DS::Buttonish < DesignSystemComponent
  VARIANTS = {
    primary: {
      container_classes: "text-inverse bg-inverse hover:bg-inverse-hover disabled:bg-gray-500 theme-dark:disabled:bg-gray-400",
      icon_classes: "text-inverse"
    },
    secondary: {
      container_classes: "text-primary bg-gray-200 theme-dark:bg-gray-700 hover:bg-gray-300 theme-dark:hover:bg-gray-600 disabled:bg-gray-200 theme-dark:disabled:bg-gray-600",
      icon_classes: "text-primary"
    },
    destructive: {
      container_classes: "text-inverse button-bg-destructive hover:button-bg-destructive-hover disabled:bg-red-200 theme-dark:disabled:bg-red-600",
      icon_classes: "text-inverse"
    },
    outline: {
      container_classes: "text-primary border border-secondary bg-transparent hover:bg-surface-hover",
      icon_classes: "text-secondary"
    },
    outline_destructive: {
      container_classes: "text-destructive border border-secondary bg-transparent hover:bg-container-inset-hover",
      icon_classes: "text-secondary"
    },
    ghost: {
      container_classes: "text-primary bg-transparent hover:bg-container-inset-hover",
      icon_classes: "text-secondary"
    },
    icon: {
      container_classes: "hover:bg-container-inset-hover",
      icon_classes: "text-secondary"
    },
    icon_inverse: {
      container_classes: "bg-inverse hover:bg-inverse-hover",
      icon_classes: "text-inverse"
    }
  }.freeze

  # Icon-only containers share a height rail with the text buttons of the
  # same size (sm ≈ 28px, md ≈ 36px, lg ≈ 48px), so a mixed row — icon
  # trigger next to text buttons, the most common header layout — lines up
  # instead of mixing 32/44px squares with 36px buttons.
  #
  # pointer-coarse restores the 44px square on touch devices: the visual
  # rail is a pointer-precision tradeoff, and WCAG 2.5.5's 44x44 target
  # minimum is about fingers, not mice. Coarse-pointer users get the full
  # target; fine-pointer users get the aligned row.
  SIZES = {
    sm: {
      container_classes: "px-2 py-1",
      icon_container_classes: "inline-flex items-center justify-center w-7 h-7 pointer-coarse:w-11 pointer-coarse:h-11",
      radius_classes: "rounded-md",
      text_classes: "text-sm"
    },
    md: {
      container_classes: "px-3 py-2",
      icon_container_classes: "inline-flex items-center justify-center w-9 h-9 pointer-coarse:w-11 pointer-coarse:h-11",
      radius_classes: "rounded-lg",
      text_classes: "text-sm"
    },
    lg: {
      container_classes: "px-4 py-3",
      icon_container_classes: "inline-flex items-center justify-center w-12 h-12",
      radius_classes: "rounded-xl",
      text_classes: "text-base"
    }
  }.freeze

  attr_reader :variant, :size, :href, :icon, :icon_custom, :icon_position, :text, :full_width, :extra_classes, :frame, :opts

  def initialize(variant: :primary, size: :md, href: nil, text: nil, icon: nil, icon_custom: false, icon_position: :left, full_width: false, frame: nil, **opts)
    @variant = variant.to_s.underscore.to_sym
    @size = size.to_sym
    @href = href
    @icon = icon
    @icon_custom = icon_custom
    @icon_position = icon_position.to_sym
    @text = text
    @full_width = full_width
    @extra_classes = opts.delete(:class)
    @frame = frame
    @opts = opts
  end

  def call
    raise NotImplementedError, "Buttonish is an abstract class and cannot be instantiated directly."
  end

  def container_classes(override_classes = nil)
    class_names(
      # Tailwind v4 preflight sets `cursor: pointer` on all <button>s, which
      # also applies while disabled. Override so disabled buttons read as
      # non-interactive. The aria-disabled twins cover buttons that gate via
      # `aria-disabled` to stay clickable/focusable (e.g. submit buttons whose
      # click handler surfaces validation errors — a truly disabled default
      # submit would also swallow Enter-key implicit submission).
      "font-medium whitespace-nowrap focus-ring disabled:cursor-not-allowed aria-disabled:cursor-not-allowed aria-disabled:opacity-50",
      merged_base_classes,
      full_width ? "w-full justify-center" : nil,
      container_size_classes,
      icon_only? ? nil : size_data.dig(:text_classes),
      variant_data.dig(:container_classes)
    )
  end

  def container_size_classes
    icon_only? ? size_data.dig(:icon_container_classes) : size_data.dig(:container_classes)
  end

  def icon_color
    # Map variant to icon color for the icon helper
    case variant
    when :primary, :icon_inverse
      :white
    when :destructive, :outline_destructive
      :destructive
    else
      :default
    end
  end

  def icon_classes
    class_names(
      variant_data.dig(:icon_classes)
    )
  end

  def icon_only?
    variant.in?([ :icon, :icon_inverse ]) || (icon.present? && text.blank?)
  end

  private
    def variant_data
      self.class::VARIANTS.dig(variant)
    end

    def size_data
      self.class::SIZES.dig(size)
    end

    # Make sure that user can override common classes like `hidden`
    def merged_base_classes
      base_display_classes = "inline-flex items-center gap-1"
      base_radius_classes = size_data.dig(:radius_classes)

      extra_classes_list = (extra_classes || "").split

      has_display_override = extra_classes_list.any? { |c| permitted_display_override_classes.include?(c) }
      has_radius_override = extra_classes_list.any? { |c| permitted_radius_override_classes.include?(c) }

      base_classes = []

      unless has_display_override
        base_classes << base_display_classes
      end

      unless has_radius_override
        base_classes << base_radius_classes
      end

      class_names(
        base_classes,
        extra_classes
      )
    end

    def permitted_radius_override_classes
      [ "rounded-full" ]
    end

    def permitted_display_override_classes
      [ "hidden", "flex" ]
    end
end
