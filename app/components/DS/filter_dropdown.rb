module DS
  class FilterDropdown < ViewComponent::Base
    attr_reader :items, :selected, :placeholder, :empty_text, :value_method, :label_method, :label

    def initialize(items:, selected: nil, placeholder: "Select...", empty_text: "No items", value_method: :id, label_method: :name, label: nil)
      @items = items
      @selected = selected
      @placeholder = placeholder
      @empty_text = empty_text
      @value_method = value_method
      @label_method = label_method
      @label = label
    end
  end
end
