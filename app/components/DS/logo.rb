# A remote logo with a local initial when the image cannot be loaded. Keep the
# fallback in the HTML so CDN failures never require another network request.
class DS::Logo < DesignSystemComponent
  attr_reader :src, :name, :class_name, :color

  def initialize(src:, name:, class_name: "w-9 h-9", color: nil)
    @src = src
    @name = name
    @class_name = class_name
    @color = color
  end
end
