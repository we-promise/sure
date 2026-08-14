Rails.application.config.after_initialize do
  DS::Dialog.defaults_provider = -> {
    { disable_click_outside: Current.user&.disable_modal_click_outside? || false }
  }
end
