class StyledFormBuilder < ActionView::Helpers::FormBuilder
  # Rails 8 renamed two field_helpers entries: :text_area -> :textarea and
  # :check_box -> :checkbox. Exclude both spellings of the non-text helpers, and
  # alias the legacy method names below so existing `form.text_area` call sites
  # stay styled. (Harmless on Rails 7.2, where the old names are present instead.)
  NON_TEXT_FIELD_HELPERS = [ :label, :check_box, :checkbox, :radio_button, :fields_for, :fields, :hidden_field, :file_field ].freeze
  class_attribute :text_field_helpers, default: field_helpers - NON_TEXT_FIELD_HELPERS

  # Options the builder handles itself instead of passing them to the input as
  # HTML attributes. `required` is left out because it's both: the builder adds
  # the label's asterisk and the input keeps the attribute.
  BUILDER_OPTIONS = [ :label, :label_tooltip, :inline, :container_class, :help_text ].freeze

  text_field_helpers.each do |selector|
    class_eval <<-RUBY_EVAL, __FILE__, __LINE__ + 1
      def #{selector}(method, options = {})
        form_options = options.slice(*BUILDER_OPTIONS, :required)
        html_options = options.except(*BUILDER_OPTIONS)

        build_field(method, form_options, html_options) do |merged_options|
          super(method, merged_options)
        end
      end
    RUBY_EVAL
  end

  # Keep `form.text_area` styled after Rails 8 renamed the helper to `textarea`.
  alias_method :text_area, :textarea if method_defined?(:textarea)

  def radio_button(method, tag_value, options = {})
    merged_options = { class: "form-field__radio" }.merge(options)
    super(method, tag_value, merged_options)
  end

  # The browser's own file button otherwise, unstyled beside every other
  # control. Given a label, it sits in the same bordered field as the rest;
  # the selector button is a compact chip, so the field keeps their height.
  # Without a label it comes back bare, as the dropzones use it: they pass
  # `hidden` and draw their own target, and the classes merge so that stays.
  #
  # The chip inherits its colour rather than taking `file:text-primary`: that
  # utility's dark variant is a `:where()` selector, which cannot follow the
  # pseudo-element, so the chip kept its light-mode text on a dark ground.
  FILE_FIELD_CLASSES = "w-full text-sm text-primary cursor-pointer " \
    "file:mr-2 file:px-2 file:rounded-md file:border-0 file:bg-container-inset " \
    "file:font-medium file:cursor-pointer hover:file:bg-container-inset-hover".freeze

  def file_field(method, options = {})
    form_options = options.slice(:label, :label_tooltip, :container_class, :required)
    html_options = options.except(:label, :label_tooltip, :container_class)
    html_options[:class] = @template.class_names(FILE_FIELD_CLASSES, html_options[:class])

    return super(method, html_options) unless form_options[:label]

    build_field(method, form_options, html_options) { |merged_options| super(method, merged_options) }
  end

  def select(method, choices, options = {}, html_options = {})
    field_options = normalize_options(options, html_options)

    build_field(method, field_options, html_options) do |merged_html_options|
      super(method, choices, options, merged_html_options)
    end
  end

  def collection_select(method, collection, value_method, text_method, options = {}, html_options = {})
    selected_value =
      if options.key?(:selected)
        options[:selected]
      elsif @object.respond_to?(method)
        @object.public_send(method)
      end
    placeholder = options[:prompt] || options[:include_blank] || options[:placeholder] || I18n.t("helpers.select.default_label")

    @template.render(
      DS::Select.new(
        form: self,
        method: method,
        items: collection.map { |item| { value: item.public_send(value_method), label: item.public_send(text_method), object: item } },
        selected: selected_value,
        placeholder: placeholder,
        searchable: options.fetch(:searchable, false),
        menu_placement: options[:menu_placement],
        variant: options.fetch(:variant, :simple),
        include_blank: options[:include_blank],
        label: options[:label],
        container_class: options[:container_class],
        label_tooltip: options[:label_tooltip],
        scoped_ids: options.fetch(:scoped_ids, false),
        html_options: html_options
      )
    )
  end

  def money_field(amount_method, options = {})
    @template.render partial: "shared/money_field", locals: {
      form: self,
      amount_method:,
      currency_method: options[:currency_method] || :currency,
      **options
    }
  end

  def toggle(method, options = {}, checked_value = "1", unchecked_value = "0")
    field_id = field_id(method)
    field_name = field_name(method)
    checked = object ? object.send(method) : options[:checked]

    @template.render(
      DS::Toggle.new(
        id: field_id,
        name: field_name,
        checked: checked,
        disabled: options[:disabled],
        checked_value: checked_value,
        unchecked_value: unchecked_value,
        **options
      )
    )
  end

  def submit(value = nil, options = {})
    value, options = nil, value if value.is_a?(Hash)
    value ||= submit_default_value

    @template.render(
      DS::Button.new(
        text: value,
        type: "submit",
        data: (options[:data] || {}).merge({ turbo_submits_with: "Submitting..." }),
        full_width: true
      )
    )
  end

  private
    def build_field(method, options = {}, html_options = {}, &block)
      if options[:help_text].present?
        help_text_id = field_id(method, :help_text)
        describedby = [ html_options.dig(:aria, :describedby), help_text_id ].compact.join(" ")
        html_options = html_options.deep_merge(aria: { describedby: describedby })
        help_text_element = @template.tag.p(options[:help_text], id: help_text_id, class: "text-xs text-secondary px-1")
      end

      # Bare fields keep their layout, so the hint follows the input unwrapped.
      if options[:inline] || options[:label] == false
        field_element = yield({ class: "form-field__input" }.merge(html_options))
        return help_text_element ? field_element + help_text_element : field_element
      end

      label_element = build_label(method, options)
      field_element = yield({ class: "form-field__input" }.merge(html_options))

      container_classes = [ "form-field", options[:container_class] ].compact

      container = @template.tag.div class: container_classes do
        if options[:label_tooltip]
          @template.tag.div(class: "form-field__header") do
            label_element +
            @template.tag.div(class: "form-field__actions") do
              build_tooltip(options[:label_tooltip])
            end
          end +
          @template.tag.div(class: "form-field__body") do
            field_element
          end
        else
          @template.tag.div(class: "form-field__body") do
            label_element + field_element
          end
        end
      end

      return container unless help_text_element

      @template.tag.div(class: "space-y-1") { container + help_text_element }
    end

    def normalize_options(options, html_options)
      options.merge(required: options[:required] || html_options[:required])
    end

    def build_label(method, options)
      return "".html_safe unless options[:label]

      label_text = options[:label]

      if options[:required]
        label_text = @template.safe_join([
          label_text == true ? method.to_s.humanize : label_text,
          @template.tag.span("*", class: "text-red-500 ml-0.5")
        ])
      end

      return label(method, class: "form-field__label") if label_text == true
      label(method, label_text, class: "form-field__label")
    end

    def build_tooltip(tooltip_text)
      return nil unless tooltip_text

      @template.tag.div(data: { controller: "tooltip" }) do
        @template.safe_join([
          @template.icon("help-circle", size: "sm", color: "default", class: "cursor-help"),
          @template.tag.div(tooltip_text, role: "tooltip", data: { tooltip_target: "tooltip" }, class: "tooltip bg-gray-700 text-sm p-2 rounded w-64 text-white")
        ])
      end
    end
end
