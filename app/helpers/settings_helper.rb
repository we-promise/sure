module SettingsHelper
  SETTINGS_ORDER = [
    # General section
    { name_key: "settings.settings_nav.accounts_label", path: :accounts_path },
    { name_key: "settings.settings_nav.bank_sync_label", path: :settings_bank_sync_path },
    { name_key: "settings.settings_nav.preferences_label", path: :settings_preferences_path },
    { name_key: "settings.settings_nav.profile_label", path: :settings_profile_path },
    { name_key: "settings.settings_nav.security_label", path: :settings_security_path },
    { name_key: "settings.settings_nav.billing_label", path: :settings_billing_path, condition: :not_self_hosted? },
    # Transactions section
    { name_key: "settings.settings_nav.categories_label", path: :categories_path },
    { name_key: "settings.settings_nav.tags_label", path: :tags_path },
    { name_key: "settings.settings_nav.rules_label", path: :rules_path },
    { name_key: "settings.settings_nav.merchants_label", path: :family_merchants_path },
    { name_key: "settings.settings_nav.recurring_transactions_label", path: :recurring_transactions_path },
    # Advanced section
    { name_key: "settings.settings_nav.ai_prompts_label", path: :settings_ai_prompts_path, condition: :admin_user? },
    { name_key: "settings.settings_nav.llm_usage_label", path: :settings_llm_usage_path, condition: :admin_user? },
    { name_key: "settings.settings_nav.api_keys_label", path: :settings_api_key_path, condition: :admin_user? },
    { name_key: "settings.settings_nav.self_hosting_label", path: :settings_hosting_path, condition: :self_hosted_and_admin? },
    { name_key: "settings.settings_nav.providers_label", path: :settings_providers_path, condition: :admin_user? },
    { name_key: "settings.settings_nav.imports_label", path: :imports_path, condition: :admin_user? },
    # More section
    { name_key: "settings.settings_nav.guides_label", path: :settings_guides_path },
    { name_key: "settings.settings_nav.whats_new_label", path: :changelog_path },
    { name_key: "settings.settings_nav.feedback_label", path: :feedback_path }
  ]

  def adjacent_setting(current_path, offset)
    visible_settings = SETTINGS_ORDER.select { |setting| setting[:condition].nil? || send(setting[:condition]) }
    current_index = visible_settings.index { |setting| send(setting[:path]) == current_path }
    return nil unless current_index

    adjacent_index = current_index + offset
    return nil if adjacent_index < 0 || adjacent_index >= visible_settings.size

    adjacent = visible_settings[adjacent_index]

    render partial: "settings/settings_nav_link_large", locals: {
      path: send(adjacent[:path]),
      direction: offset > 0 ? "next" : "previous",
      title: I18n.t(adjacent[:name_key])
    }
  end

  def settings_section(title:, subtitle: nil, collapsible: false, open: true, &block)
    content = capture(&block)
    render partial: "settings/section", locals: { title: title, subtitle: subtitle, content: content, collapsible: collapsible, open: open }
  end

  def settings_nav_footer
    previous_setting = adjacent_setting(request.path, -1)
    next_setting = adjacent_setting(request.path, 1)

    content_tag :div, class: "hidden md:flex flex-row justify-between gap-4" do
      concat(previous_setting)
      concat(next_setting)
    end
  end

  def settings_nav_footer_mobile
    previous_setting = adjacent_setting(request.path, -1)
    next_setting = adjacent_setting(request.path, 1)

    content_tag :div, class: "md:hidden flex flex-col gap-4" do
      concat(previous_setting)
      concat(next_setting)
    end
  end

  private
    def not_self_hosted?
      !self_hosted?
    end

    # Helper used by SETTINGS_ORDER conditions
    def admin_user?
      Current.user&.admin?
    end

    def self_hosted_and_admin?
      self_hosted? && admin_user?
    end
end
