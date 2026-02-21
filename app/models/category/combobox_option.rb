class Category::ComboboxOption
  include ActiveModel::Model

  attr_accessor :category

  delegate :id, :color, :lucide_icon, :name, :details, :parent_id, to: :category

  def combobox_value
    id
  end

  def combobox_display
    to_combobox_display
  end

  def combobox_details
    details
  end

  def to_combobox_display
    name
  end

end
