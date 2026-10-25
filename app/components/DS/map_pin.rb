# Category marker used by iCost maps.
class DS::MapPin < DesignSystemComponent
  def initialize(category: nil)
    @category = category
  end

  def call
    tag.div(class: "flex items-center justify-center rounded-full border-2 border-white shadow-md w-10 h-10 text-white",
      style: @category ? "background-color: #{@category.color}" : "background-color: var(--utility-text-secondary)",
      data: { icost_pin: true }) do
      safe_join([
        render(DS::IconGlyph.new(icon: @category&.lucide_icon || "map-pin", emoji: @category&.emoji, size: "lg", color: "current", data: { pin_icon: true })),
        tag.span("", class: "hidden text-sm font-semibold", data: { pin_count: true })
      ])
    end
  end
end
