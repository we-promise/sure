module Settings::ClassifiersHelper
  # One auto-submitting form per Settings → Classifier section: only its
  # fields are sent, and the controller merges them into the stored settings.
  # A helper, not a layout partial, so t(".key") inside still resolves
  # against the section's own partial. Its builder names fields
  # bayes_settings[...], for DS::Select.
  def classifier_section_form(&block)
    form_with url: settings_classifier_path, method: :patch, scope: :bayes_settings, class: "space-y-4",
              data: { controller: "auto-submit-form", auto_submit_form_trigger_event_value: "change" }, &block
  end
end
