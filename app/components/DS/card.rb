class DS::Card < DesignSystemComponent
  # Nesting level controls the corner radius. Outer cards (rounded-xl) live
  # directly on the page; inner cards (rounded-lg) nest inside an outer; tight
  # cards (rounded-md) cover compact list-group containers. Standardizing the
  # radius per nesting level removes the "stacked containers with the same
  # radius" problem flagged in #2135.
  LEVELS = %i[outer inner tight].freeze

  PADDINGS = {
    none: "",
    xs:   "p-2",
    sm:   "p-3",
    md:   "p-4",
    lg:   "p-6",
    xl:   "p-12"
  }.freeze

  def initialize(level: :outer, padding: :md, overflow_hidden: false, tag: :div, **html_attrs)
    @level = normalize_level(level)
    @padding = normalize_padding(padding)
    @overflow_hidden = overflow_hidden
    @tag = tag
    @html_attrs = html_attrs
  end

  def call
    classes = class_names(container_classes, @html_attrs.delete(:class))
    helpers.tag.send(@tag, class: classes, **@html_attrs) { content }
  end

  private
    attr_reader :level, :padding, :overflow_hidden

    def normalize_level(raw)
      sym = raw.respond_to?(:to_sym) ? raw.to_sym : nil
      LEVELS.include?(sym) ? sym : :outer
    end

    def normalize_padding(raw)
      sym = raw.respond_to?(:to_sym) ? raw.to_sym : nil
      PADDINGS.key?(sym) ? sym : :md
    end

    def container_classes
      class_names(
        "bg-container shadow-border-xs",
        radius_class,
        PADDINGS[padding].presence,
        ("overflow-hidden" if overflow_hidden)
      )
    end

    def radius_class
      case level
      when :outer then "rounded-xl"
      when :inner then "rounded-lg"
      when :tight then "rounded-md"
      end
    end
end
