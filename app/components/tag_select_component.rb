class TagSelectComponent < ApplicationComponent
  attr_reader :form, :tags, :selected_ids, :disabled, :auto_submit, :update_url

  def initialize(form:, tags:, selected_ids:, disabled: false, auto_submit: false, update_url: nil)
    @form = form
    @tags = tags
    @selected_ids = selected_ids.map(&:to_s)
    @disabled = disabled
    @auto_submit = auto_submit
    @update_url = update_url
  end

  def field_name
    "#{form.object_name}[tag_ids][]"
  end
end
