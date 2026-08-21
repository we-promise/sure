# Native <input type="date"> paints in the browser/OS locale. Show a text
# field in the family's date_format so the user can type, and keep a hidden
# type=date for the ISO value and the calendar picker.
module LocalizedDateField
  def date_field(method, options = {})
    options = options.dup
    visual_class = options.delete(:class)
    placeholder = options.delete(:placeholder)
    format = Current.family&.date_format.presence || "%Y-%m-%d"
    iso = localized_date_iso(method, options)
    display = iso.present? ? Date.iso8601(iso).strftime(format) : ""
    text_id = field_id(method)

    @template.tag.div(
      class: "relative",
      data: { localized_date: true, format: format }
    ) do
      @template.safe_join([
        @template.tag.input(
          type: "text",
          id: text_id,
          value: display,
          placeholder: placeholder,
          autocomplete: "off",
          inputmode: "numeric",
          class: [ "min-w-0 grow tabular-nums pr-10", visual_class ].compact.join(" "),
          data: { localized_date_display: true }
        ),
        @template.tag.button(
          type: "button",
          class: "absolute inset-y-0 right-2 flex items-center text-secondary",
          data: { localized_date_picker: true },
          tabindex: "-1",
          aria: { label: I18n.t("helpers.label.date", default: "Choose date") }
        ) { @template.icon("calendar", size: "sm") },
        super(method, options.merge(class: "sr-only", id: "#{text_id}_picker", value: iso)),
        localized_date_boot
      ])
    end
  end

  private
    def localized_date_iso(method, options)
      raw = options[:value]
      raw = object.public_send(method) if raw.nil? && object.respond_to?(method)
      return if raw.blank?

      date = raw.respond_to?(:to_date) ? raw.to_date : Date.parse(raw.to_s)
      date.iso8601
    rescue Date::Error, ArgumentError
      nil
    end

    def localized_date_boot
      return "".html_safe if @template.instance_variable_defined?(:@_localized_date_boot)

      @template.instance_variable_set(:@_localized_date_boot, true)
      @template.render("shared/localized_date_boot")
    end
end

Rails.application.config.to_prepare do
  unless ActionView::Helpers::FormBuilder.ancestors.include?(LocalizedDateField)
    ActionView::Helpers::FormBuilder.prepend(LocalizedDateField)
  end
end
