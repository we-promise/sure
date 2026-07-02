class DS::EmptyState < DesignSystemComponent
  # `:card` wraps the content in standard container chrome (bg-container,
  # rounded-xl, shadow-border-xs). `:plain` is a bare centered block — used
  # inside surfaces that already provide their own chrome.
  VARIANTS = %i[card plain].freeze

  # Size controls outer padding and the icon/title scale. Roughly:
  #   :sm — inline / dense (entries, recurring-transactions)
  #   :md — default page-level placeholder
  #   :lg — full-bleed "no data yet" page (e.g. reports landing)
  SIZES = %i[sm md lg].freeze

  # `:plain` renders the icon directly with a subdued color. `:filled` puts
  # the icon inside a rounded surface-inset disc — matches the goals page
  # empty state and the audit's recommended treatment for "first-time"
  # placeholders.
  ICON_STYLES = %i[plain filled].freeze

  # Allowed heading tags for the title. `:h3` is the default since the
  # primitive most often appears beneath a page-level `<h1>`/`<h2>`; pass
  # `heading_tag: :h2` when the empty state IS the page's top-of-flow
  # heading. Allow-listing prevents arbitrary tag injection through the
  # public_send call in the template.
  HEADING_TAGS = %i[h1 h2 h3 h4 h5 h6].freeze

  def initialize(title:, description: nil, icon: nil, icon_style: :plain,
                 variant: :card, size: :md, heading_tag: :h3)
    raise ArgumentError, "title is required" if title.blank?

    @title = title
    @description = description
    @icon = icon
    @icon_style = normalize_enum(icon_style, ICON_STYLES, :plain)
    @variant = normalize_enum(variant, VARIANTS, :card)
    @size = normalize_enum(size, SIZES, :md)
    @heading_tag = normalize_enum(heading_tag, HEADING_TAGS, :h3)
  end

  private
    attr_reader :title, :description, :icon, :icon_style, :variant, :size, :heading_tag

    def normalize_enum(raw, allowed, fallback)
      sym = raw.respond_to?(:to_sym) ? raw.to_sym : nil
      allowed.include?(sym) ? sym : fallback
    end

    def container_classes
      base = "flex flex-col items-center text-center mx-auto"

      padding = case size
      when :sm then "py-10 px-4"
      when :md then "py-12 px-6"
      when :lg then "py-20 px-6"
      end

      chrome = (variant == :card) ? "bg-container rounded-xl shadow-border-xs" : ""

      class_names(chrome, padding, base)
    end

    def inner_max_width
      "max-w-md"
    end

    def icon_size
      case size
      when :sm then "md"
      when :md then "lg"
      when :lg then "2xl"
      end
    end

    def icon_wrapper_classes
      return nil if icon.blank?

      if icon_style == :filled
        disc_size = case size
        when :sm then "w-16 h-16"
        when :md then "w-20 h-20"
        when :lg then "w-24 h-24"
        end
        "#{disc_size} rounded-full bg-surface-inset flex items-center justify-center mb-5 text-secondary"
      else
        "text-subdued mb-6"
      end
    end

    def title_classes
      case size
      when :sm then "text-sm font-medium text-primary"
      when :md then "text-lg font-medium text-primary"
      when :lg then "text-xl font-medium text-primary"
      end
    end

    def description_classes
      case size
      when :sm then "text-sm text-secondary"
      when :md then "text-sm text-secondary leading-relaxed"
      when :lg then "text-base text-secondary"
      end
    end

    def title_margin_class
      description.present? || content.present? ? "mb-3" : nil
    end

    def description_margin_class
      content.present? ? "mb-6" : nil
    end
end
