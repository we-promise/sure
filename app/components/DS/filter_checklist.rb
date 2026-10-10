class DS::FilterChecklist < DesignSystemComponent
  attr_reader :name, :options, :selected_ids, :label

  def initialize(name:, options:, selected_ids:, label:)
    @name = name
    @options = options
    @selected_ids = selected_ids
    @label = label
  end
end
