# An inline-editable text value: the input looks like the row's value text and
# reveals a pencil affordance on its right. Use it inside a form row, typically
# DS::DetailRow's value slot, when the value should stay part of the surrounding
# summary instead of becoming a boxed form field.
#
# The caller supplies the accessible name because the visible row label usually
# lives in a sibling <dt>, not in this component.
class DS::InlineEdit < DesignSystemComponent
  attr_reader :form, :method, :value, :aria_label, :required, :autocomplete, :opts

  def initialize(form:, method:, value:, aria_label:, required: true, autocomplete: "off", **opts)
    @form = form
    @method = method
    @value = value
    @aria_label = aria_label
    @required = required
    @autocomplete = autocomplete
    @opts = opts
  end

  def input_id
    form.field_id(method)
  end

  def input_classes
    class_names(
      "min-w-0 max-w-full field-sizing-content bg-transparent border-0 p-0 text-right text-sm font-medium text-primary",
      opts[:class]
    )
  end

  def input_options
    options = opts.except(:class, :aria)
    options.merge(
      value: value,
      size: [ value.to_s.length, 4 ].max,
      inline: true,
      required: required,
      autocomplete: autocomplete,
      class: input_classes,
      aria: { label: aria_label }.merge(opts[:aria] || {})
    )
  end
end
