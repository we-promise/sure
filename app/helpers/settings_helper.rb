module SettingsHelper
  SETTINGS_ORDER = [
    # General section
    { name: "Accounts", path: :accounts_path },
    { name: "Bank Sync", path: :settings_bank_sync_path },
    { name: "Preferences", path: :settings_preferences_path },
    { name: "Profile Info", path: :settings_profile_path },
    { name: "Security", path: :settings_security_path },
    { name: "Payment", path: :settings_payment_path, condition: :not_self_hosted? },
    # Transactions section
    { name: "Categories", path: :categories_path },
    { name: "Tags", path: :tags_path },
    { name: "Rules", path: :rules_path },
    { name: "Merchants", path: :family_merchants_path },
    { name: "Recurring", path: :recurring_transactions_path },
    # Advanced section
    { name: "AI Prompts", path: :settings_ai_prompts_path, condition: :admin_user? },
    { name: "LLM Usage", path: :settings_llm_usage_path, condition: :admin_user? },
    { name: "API Key", path: :settings_api_key_path, condition: :admin_user? },
    { name: "Self-Hosting", path: :settings_hosting_path, condition: :self_hosted_and_admin? },
    { name: "Providers", path: :settings_providers_path, condition: :admin_user? },
    { name: "Imports", path: :imports_path, condition: :admin_user? },
    { name: "Exports", path: :family_exports_path, condition: :admin_user? },
    # More section
    { name: "Guides", path: :settings_guides_path },
    { name: "What's new", path: :changelog_path },
    { name: "Feedback", path: :feedback_path }
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
      title: adjacent[:name]
    }
  end

  def settings_section(title:, subtitle: nil, collapsible: false, open: true, auto_open_param: nil, &block)
    content = capture(&block)
    render partial: "settings/section", locals: { title: title, subtitle: subtitle, content: content, collapsible: collapsible, open: open, auto_open_param: auto_open_param }
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

    content_tag :div, class: "md:hidden flex flex-col gap-4 pb-[env(safe-area-inset-bottom)]" do
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
