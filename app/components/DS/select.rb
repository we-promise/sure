module DS
  class Select < ViewComponent::Base
    attr_reader :form, :method, :items, :selected_value, :placeholder, :variant, :searchable, :options

    VARIANTS = %i[simple logo badge].freeze
    HEX_COLOR_REGEX = /\A#[0-9a-fA-F]{3}(?:[0-9a-fA-F]{3})?\z/
    RGB_COLOR_REGEX = /\Argb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\)\z/
    DEFAULT_COLOR = "#737373"

    def initialize(form:, method:, items:, selected: nil, placeholder: I18n.t("helpers.select.default_label"), variant: :simple, include_blank: nil, searchable: false, **options)
      @form = form
      @method = method
      @placeholder = placeholder
      @variant = variant
      @searchable = searchable
      @options = options

      normalized_items = normalize_items(items)

      if include_blank
        normalized_items.unshift({
          value: nil,
          label: include_blank,
          object: nil
        })
      end

      @items = normalized_items
      @selected_value = selected
    end

    def selected_item
      items.find { |item| item[:value] == selected_value }
    end

    # Returns the color for a given item (used in :badge variant)
    def color_for(item)
      obj = item[:object]
      color = obj&.respond_to?(:color) ? obj.color : DEFAULT_COLOR

      return DEFAULT_COLOR unless color.is_a?(String)

      if color.match?(HEX_COLOR_REGEX) || color.match?(RGB_COLOR_REGEX)
        color
      else
        DEFAULT_COLOR
      end
    end

    # Returns the lucide_icon name for a given item (used in :badge variant)
    def icon_for(item)
      obj = item[:object]
      obj&.respond_to?(:lucide_icon) ? obj.lucide_icon : nil
    end

    # Returns true if the item has a logo (used in :logo variant)
    def logo_for(item)
      obj = item[:object]
      obj&.respond_to?(:logo_url) && obj.logo_url.present? ? Setting.transform_brand_fetch_url(obj.logo_url) : nil
    end

    private

      def normalize_items(collection)
        collection.map do |item|
          case item
          when Hash
            {
              value: item[:value],
              label: item[:label],
              object: item[:object]
            }
          else
            {
              value: item.id,
              label: item.name,
              object: item
            }
          end
        end
      end
  end
end
