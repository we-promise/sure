module DS
  class FilterDropdown < ViewComponent::Base
    attr_reader :items, :selected, :placeholder, :empty_text,
                :value_method, :label_method, :label, :searchable, :variant

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
      variant: :simple
    )
      @items = items
      @selected = selected
      @placeholder = placeholder
      @empty_text = empty_text
      @value_method = value_method
      @label_method = label_method
      @label = label
      @searchable = searchable
      @variant = variant.to_sym

      raise ArgumentError, "Invalid variant: #{@variant}" unless VARIANTS.include?(@variant)
    end

    private

    def value_for(item)
      if item.is_a?(Array) && value_method.is_a?(Integer)
        item[value_method]
      elsif item.is_a?(Array)
        item.last
      elsif item.is_a?(Hash)
        item[value_method]
      else
        item.public_send(value_method)
      end
    end

    def label_for(item)
      if item.is_a?(Array) && label_method.is_a?(Integer)
        item[label_method]
      elsif item.is_a?(Array)
        item.first
      elsif item.is_a?(Hash)
        item[label_method]
      else
        item.public_send(label_method)
      end
    end
  end
end