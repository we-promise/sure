module DS
  class FilterDropdown < ViewComponent::Base
    attr_reader :form, :method, :items, :selected_value, :placeholder, :variant, :searchable, :options

    VARIANTS = %i[simple logo badge].freeze
    DEFAULT_COLOR = "#737373"

    def initialize(form:, method:, items:, selected: nil, placeholder: "Select...", variant: :simple, include_blank: nil, searchable: false, **options)
      @form = form
      @method = method
      @selected_value = selected
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
      obj&.respond_to?(:color) ? obj.color : DEFAULT_COLOR
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
