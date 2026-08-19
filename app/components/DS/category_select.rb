class DS::CategorySelect < DesignSystemComponent
  attr_reader :form, :categories, :selected_id, :disabled, :auto_submit, :blank_label

  def initialize(
    form:,
    categories:,
    selected_id: nil,
    disabled: false,
    auto_submit: false,
    blank_label: nil
  )
    @form = form
    @categories = categories
    @selected_id = selected_id&.to_s
    @disabled = disabled
    @auto_submit = auto_submit
    @blank_label = blank_label
  end

  def field_name
    "#{form.object_name}[category_id]"
  end

  def menu_id
    @menu_id ||= "category_select_#{field_name.gsub(/\W+/, "_")}_#{object_id}"
  end
end
