module SettingsHelper
  def settings_order
    [
      # General section
      { name: I18n.t("breadcrumbs.accounts"), path: :accounts_path },
      { name: I18n.t("breadcrumbs.bank_sync"), path: :settings_bank_sync_path },
      { name: I18n.t("breadcrumbs.preferences"), path: :settings_preferences_path },
      { name: I18n.t("breadcrumbs.profiles"), path: :settings_profile_path },
      { name: I18n.t("breadcrumbs.securities"), path: :settings_security_path },
      { name: I18n.t("breadcrumbs.payments"), path: :settings_payment_path, condition: :not_self_hosted? },
      # Transactions section
      { name: I18n.t("breadcrumbs.categories"), path: :categories_path },
      { name: I18n.t("breadcrumbs.tags"), path: :tags_path },
      { name: I18n.t("breadcrumbs.rules"), path: :rules_path },
      { name: I18n.t("breadcrumbs.merchants"), path: :family_merchants_path },
      { name: I18n.t("breadcrumbs.recurring_transactions"), path: :recurring_transactions_path },
      # Advanced section
      { name: I18n.t("breadcrumbs.ai_prompts"), path: :settings_ai_prompts_path, condition: :admin_user? },
      { name: I18n.t("breadcrumbs.llm_usages"), path: :settings_llm_usage_path, condition: :admin_user? },
      { name: I18n.t("breadcrumbs.api_keys"), path: :settings_api_key_path, condition: :admin_user? },
      { name: I18n.t("breadcrumbs.hostings"), path: :settings_hosting_path, condition: :self_hosted_and_admin? },
      { name: I18n.t("breadcrumbs.providers"), path: :settings_providers_path, condition: :admin_user? },
      { name: I18n.t("breadcrumbs.imports"), path: :imports_path, condition: :admin_user? },
      { name: I18n.t("breadcrumbs.exports"), path: :family_exports_path, condition: :admin_user? },
      # More section
      { name: I18n.t("breadcrumbs.guides"), path: :settings_guides_path },
      { name: I18n.t("breadcrumbs.changelog"), path: :changelog_path },
      { name: I18n.t("breadcrumbs.feedback"), path: :feedback_path }
    ]
  end

  def adjacent_setting(current_path, offset)
    visible_settings = settings_order.select { |setting| setting[:condition].nil? || send(setting[:condition]) }
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
