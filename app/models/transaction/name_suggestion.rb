class Transaction::NameSuggestion
  include ActiveModel::Model

  attr_accessor :name, :category

  def to_combobox_display
    name
  end
end
