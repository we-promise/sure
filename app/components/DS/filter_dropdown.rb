module DS
  class FilterDropdown < ViewComponent::Base
    attr_reader :items, :selected_value, :placeholder,
                :empty_text, :value_method, :label_method,
                :label, :searchable, :variant

    VARIANTS = %i[simple icon badge].freeze
    DEFAULT_COLOR = "#737373"

    def initialize(
      items:,
      selected: nil,
      placeholder: "Select...",
      empty_text: "No items",
      value_method: :id,
      label_method: :name,
      label: nil,
      searchable: true,
      variant: :simple,
      include_blank: nil
    )
      @value_method = value_method
      @label_method = label_method
      @placeholder = placeholder
      @empty_text = empty_text
      @label = label
      @searchable = searchable
      @variant = variant.to_sym

      raise ArgumentError, "Invalid variant: #{@variant}" unless VARIANTS.include?(@variant)

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

    private

    def normalize_items(collection)
      collection.map do |item|
        case item
        when Hash
          {
            value: item[:value] || item[value_method],
            label: item[:label] || item[label_method],
            object: item[:object]
          }
        else
          {
            value: item.public_send(value_method),
            label: item.public_send(label_method),
            object: item
          }
        end
      end
    end
  end
end