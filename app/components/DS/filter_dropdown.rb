module DS
  class FilterDropdown < ViewComponent::Base
    attr_reader :items, :selected, :placeholder, :empty_text, :value_method, :label_method, :label, :searchable

    def initialize(items:, selected: nil, placeholder: "Select...", empty_text: "No items", value_method: :id, label_method: :name, label: nil, searchable: true)
      @items = items
      @selected = selected
      @placeholder = placeholder
      @empty_text = empty_text
      @value_method = value_method
      @label_method = label_method
      @label = label
      @searchable = searchable
    end
  end
end

private

def value_for(item)
  item.respond_to?(value_method) ? item.public_send(value_method) : item[value_method]
end

def label_for(item)
  item.respond_to?(label_method) ? item.public_send(label_method) : item[label_method]
end