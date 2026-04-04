module DS
  class MultiSelectTags < ViewComponent::Base
    attr_reader :form, :method, :tags, :selected_ids, :label, :disabled, :input_options, :dropdown_label

    def initialize(form:, method:, tags:, selected_ids: [], label: nil, disabled: false, input_options: {}, dropdown_label: nil)
      @form = form
      @method = method
      @tags = tags
      @selected_ids = Array(selected_ids).map(&:to_s)
      @selected_id_lookup = @selected_ids.each_with_object({}) { |id, memo| memo[id] = true }
      @label = label
      @disabled = disabled
      @input_options = input_options
      @dropdown_label = dropdown_label || I18n.t("helpers.select.default_label")
    end

    def checkbox_id(tag)
      scope = form.object_name.to_s.gsub(/\]\[|\[|\]/, "_").gsub(/_+\z/, "")
      "#{scope}_#{method}_#{tag.id}"
    end

    def selected?(tag)
      @selected_id_lookup.key?(tag.id.to_s)
    end

    def tag_color(tag)
      tag.color.presence || Tag::UNCATEGORIZED_COLOR
    end

    def selected_chip_style(color)
      "background-color: color-mix(in oklab, #{color} 14%, transparent); " \
      "border-color: color-mix(in oklab, #{color} 28%, transparent); color: #{color}"
    end

    def option_chip_style(color)
      "background-color: color-mix(in oklab, #{color} 10%, transparent); " \
      "border-color: color-mix(in oklab, #{color} 20%, transparent); color: #{color}"
    end
  end
end
