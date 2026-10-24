# A decorative glyph that preserves a whole emoji sequence and retains Lucide fallback.
class DS::IconGlyph < DesignSystemComponent
  SIZES = {
    "xs" => "w-3 h-3 text-xs", "sm" => "w-4 h-4 text-base",
    "md" => "w-5 h-5 text-lg", "lg" => "w-6 h-6 text-xl",
    "xl" => "w-7 h-7 text-2xl", "2xl" => "w-8 h-8 text-3xl"
  }.freeze

  def initialize(icon: nil, emoji: nil, size: "sm", color: "current", **options)
    @icon, @emoji, @size, @color, @options = icon, emoji, size.to_s, color, options
  end

  def call
    if @emoji.present?
      tag.span(@emoji, **@options.merge(
        class: class_names("inline-flex items-center justify-center shrink-0 leading-none", SIZES.fetch(@size, SIZES["sm"]), @options[:class]),
        aria: { hidden: true }, data: (@options[:data] || {}).merge(emoji_glyph: true)
      ))
    else
      helpers.icon(@icon, size: @size, color: @color, **@options.merge(aria: { hidden: true }))
    end
  end
end
