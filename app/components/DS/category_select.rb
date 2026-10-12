class DS::CategorySelect < DesignSystemComponent
  attr_reader :form, :categories, :selected_id, :disabled, :auto_submit, :blank_label

  def initialize(
    form:,
    categories:,
    selected_id: nil,
    selected_category: nil,
    disabled: false,
    auto_submit: false,
    blank_label: nil
  )
    @form = form
    @categories = categories
    @selected_id = selected_id&.to_s
    @selected_category = selected_category
    @disabled = disabled
    @auto_submit = auto_submit
    @blank_label = blank_label
  end

  # A category shown as the selection without being one of `categories`,
  # e.g. a virtual or read-only category on a disabled select.
  def selected_category
    @selected_category || categories.find { |category| category.id.to_s == selected_id }
  end

  def field_name
    "#{form.object_name}[category_id]"
  end

  def field_id
    form.field_id(:category_id)
  end

  def trigger_id
    "category_id_trigger"
  end

  def menu_id
    "#{field_id}_menu"
  end

  def parent_label_id
    "#{menu_id}_parent_label"
  end

  # Only top-level categories can be parents (categories are two levels deep).
  def parent_options
    categories.select { |category| category.parent_id.nil? }.sort_by { |category| category.name.downcase }
  end
end
