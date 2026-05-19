class DS::FilledIcon < DesignSystemComponent
  attr_reader :icon, :text, :hex_color, :size, :rounded, :variant, :description, :aria_hidden

  VARIANTS = %i[default text surface container inverse].freeze

  SIZES = {
    sm: {
      container_size: "w-6 h-6",
      container_radius: "rounded-md",
      icon_size: "sm",
      text_size: "text-xs"
    },
    md: {
      container_size: "w-8 h-8",
      container_radius: "rounded-lg",
      icon_size: "md",
      text_size: "text-xs"
    },
    lg: {
      container_size: "w-9 h-9",
      container_radius: "rounded-xl",
      icon_size: "lg",
      text_size: "text-sm"
    }
  }.freeze

  # `description:` makes the icon meaningful — emits `role="img"` +
  # `aria-label=description` so AT users hear it. Without `description:`,
  # the wrapper defaults to `aria-hidden="true"` (decorative) on the
  # assumption that adjacent DOM carries the accessible name. Pass
  # `aria_hidden: false` if you want the visual exposed but the name
  # already lives in surrounding text (rare).
  #
  # NOTE on the `:text` variant: only `text.first` is rendered (e.g.
  # "Apple" → "A"). The single letter is decorative — relying on AT
  # users to infer "Apple" from "A" is broken. Use `description:` to
  # surface the full label, or ensure the adjacent text node carries it.
  def initialize(variant: :default, icon: nil, text: nil, hex_color: nil, size: "md", rounded: false, description: nil, aria_hidden: nil)
    @variant = variant.to_sym
    @icon = icon
    @text = text
    @hex_color = hex_color
    @size = size.to_sym
    @rounded = rounded
    @description = description.presence
    @aria_hidden = aria_hidden.nil? ? @description.blank? : aria_hidden
  end

  def container_classes
    class_names(
      "flex justify-center items-center shrink-0",
      size_classes,
      radius_classes,
      transparent? ? "border" : solid_bg_class
    )
  end

  def icon_size
    SIZES[size][:icon_size]
  end

  def text_classes
    class_names(
      "text-center font-medium uppercase",
      SIZES[size][:text_size]
    )
  end

  def container_styles
    <<~STYLE.strip
      background-color: #{transparent_bg_color};
      border-color: #{transparent_border_color};
      color: #{custom_fg_color};
    STYLE
  end

  def transparent?
    variant.in?(%i[default text])
  end

  private
    def solid_bg_class
      case variant
      when :surface
        "bg-surface-inset"
      when :container
        "bg-container-inset"
      when :inverse
        "bg-container"
      end
    end

    def size_classes
      SIZES[size][:container_size]
    end

    def radius_classes
      rounded ? "rounded-full" : SIZES[size][:container_radius]
    end

    def custom_fg_color
      hex_color || "var(--color-gray-500)"
    end

    def transparent_bg_color
      "color-mix(in oklab, #{custom_fg_color} 10%, transparent)"
    end

    def transparent_border_color
      "color-mix(in oklab, #{custom_fg_color} 10%, transparent)"
    end
end
