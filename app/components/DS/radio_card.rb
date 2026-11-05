class DS::RadioCard < DesignSystemComponent
  attr_reader :form, :method, :value, :label, :hint, :radio_opts

  # Bordered, selectable radio option with a label + hint, highlighting when
  # checked. Extracted from goal-kind (goals/_form.html.erb) and Enable
  # Banking sync-strategy (enable_banking_items/setup_accounts.html.erb),
  # which had this exact shape hand-rolled twice (PR #3811 review) — reach
  # for this instead of repeating the class string for the next radio group.
  def initialize(form:, method:, value:, label:, hint:, **radio_opts)
    @form = form
    @method = method
    @value = value
    @label = label
    @hint = hint
    @radio_opts = radio_opts
  end

  def radio_button_opts
    radio_opts.merge(class: class_names("radio mt-0.5 shrink-0", radio_opts[:class]))
  end
end
