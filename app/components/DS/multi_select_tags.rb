module DS
  class MultiSelectTags < ViewComponent::Base
    attr_reader :form, :method, :tags, :selected_ids, :label, :disabled, :input_options, :dropdown_label

    def initialize(form:, method:, tags:, selected_ids: [], label: nil, disabled: false, input_options: {}, dropdown_label: nil)
      @form = form
      @method = method
      @tags = tags
      @selected_ids = Array(selected_ids).map(&:to_s)
      @label = label
      @disabled = disabled
      @input_options = input_options
      @dropdown_label = dropdown_label || I18n.t("helpers.select.default_label")
    end

    def checkbox_id(tag)
      scope = form.object_name.to_s.gsub(/\]\[|\[|\]/, "_").gsub(/_+\z/, "")
      "#{scope}_#{method}_#{tag.id}"
    end
  end
end
