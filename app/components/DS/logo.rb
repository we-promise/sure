# A decorative logo using the ProviderLogo recipe: local initials underneath
# an opaque image, revealed when a failed image removes itself.
class DS::Logo < DesignSystemComponent
  SIZES = { xs: "w-5 h-5", sm: "w-6 h-6", md: "w-8 h-8", lg: "w-9 h-9", xl: "w-10 h-10" }.freeze

  attr_reader :src, :name, :color, :text_length, :class_name

  def initialize(src:, name:, size: :lg, color: nil, text_length: 1, class_name: nil)
    @src = src
    @name = name
    @size = size.to_sym
    @color = color
    @text_length = text_length
    @class_name = class_name
  end

  def container_classes
    class_names("relative block shrink-0 overflow-hidden rounded-full", SIZES.fetch(@size), class_name)
  end

  def letter_size
    { xs: :sm, xl: :lg }.fetch(@size, @size)
  end
end
