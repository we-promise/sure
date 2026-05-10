module SettingsHelper
  SETTINGS_ORDER = [
    # General section
    { name: "Accounts", path: :accounts_path },
    { name: "Bank Sync", path: :settings_providers_path, condition: :admin_user? },
    { name: "Preferences", path: :settings_preferences_path },
    { name: "Appearance", path: :settings_appearance_path },
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

  def settings_section(title:, subtitle: nil, collapsible: false, open: true, auto_open_param: nil, status: nil, meta: nil, actions: nil, badge: nil, &block)
    content = capture(&block)
    render partial: "settings/section", locals: { title: title, subtitle: subtitle, content: content, collapsible: collapsible, open: open, auto_open_param: auto_open_param, status: status, meta: meta, actions: actions, badge: badge }
  end

  def status_pill_classes(status)
    pill = "bg-surface-inset text-primary"

    case status.to_s.to_sym
    when :ok
      { dot: "bg-success", pill: pill }
    when :warn
      { dot: "bg-warning", pill: pill }
    when :err
      { dot: "bg-destructive", pill: pill }
    else
      { dot: "bg-gray-400", pill: pill }
    end
  end

  def provider_summary(provider_key)
    key = provider_key.to_s.downcase

    case key
    when "plaid", "plaid_eu"
      configured = @provider_configurations&.find { |c| c.provider_key.to_s.casecmp(key).zero? }&.configured?
      configured ? { status: :ok } : { status: :off }
    when "simplefin"
      return { status: :off } unless @simplefin_items&.any?
      sync_based_summary(key)
    when "lunchflow"
      return { status: :off } unless @lunchflow_items&.any?
      sync_based_summary(key)
    when "enable_banking"
      return { status: :off } unless @enable_banking_items&.any?
      enable_banking_summary
    when "coinstats"
      return { status: :off } unless @coinstats_items&.any?
      sync_based_summary(key)
    when "mercury"
      return { status: :off } unless @mercury_items&.any?
      sync_based_summary(key)
    when "coinbase"
      return { status: :off } unless @coinbase_items&.any?
      sync_based_summary(key)
    when "binance"
      return { status: :off } unless @binance_items&.any?
      sync_based_summary(key)
    when "snaptrade"
      configured_item = @snaptrade_items&.find(&:credentials_configured?)
      return { status: :off } unless configured_item
      unless configured_item.user_registered?
        return { status: :warn, meta: t("settings.providers.meta.registration_needed") }
      end
      sync_based_summary(key)
    when "indexa_capital"
      return { status: :off } unless @indexa_capital_items&.any?
      sync_based_summary(key)
    when "sophtron"
      return { status: :off } unless @sophtron_items&.any?
      sync_based_summary(key)
    else
      { status: :off }
    end
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

  # Below this many synced accounts, the per-row pills already give the user
  # enough at-a-glance signal and the strip is redundant chrome.
  HEALTH_STRIP_MIN_ACCOUNTS = 10

  # Slim health-strip data for the providers index. Pulls counts from the
  # already-resolved entry summaries plus the family's distinct synced-account
  # count for the trailing stat. Returns a hash consumed by the
  # `settings/providers/_health_strip` partial, or nil when the family has
  # fewer than HEALTH_STRIP_MIN_ACCOUNTS connected accounts.
  def provider_health_strip(connected:, needs_attention:)
    accounts_count = Current.family.accounts.joins(:account_providers).distinct.count
    return nil if accounts_count < HEALTH_STRIP_MIN_ACCOUNTS

    active_entries = connected + needs_attention
    last_synced_at = active_entries.map { |e| e[:summary][:last_synced_at] }.compact.max

    {
      connected:        active_entries.size,
      needs_attention:  needs_attention.size,
      accounts_syncing: accounts_count,
      last_synced_at:   last_synced_at
    }
  end

  # Strips the leading "about " from `time_ago_in_words` so copy reads as
  # "Synced 6 hours ago" instead of "Synced about 6 hours ago".
  def concise_time_ago(time)
    time_ago_in_words(time).sub(/\Aabout /, "")
  end

  private
    def sync_based_summary(provider_key)
      health = @provider_sync_health&.dig(provider_key) || {}
      last_synced_at = health[:last_synced_at]

      base = if health[:error]
        { status: :err, meta: t("settings.providers.meta.sync_error") }
      elsif health[:stale]
        { status: :warn, meta: t("settings.providers.meta.no_recent_sync") }
      elsif last_synced_at.present?
        { status: :ok, meta: t("settings.providers.meta.last_synced", time: concise_time_ago(last_synced_at)) }
      else
        { status: :ok }
      end

      base.merge(last_synced_at: last_synced_at)
    end

    def enable_banking_summary
      health = @provider_sync_health&.dig("enable_banking") || {}
      last_synced_at = health[:last_synced_at]

      return { status: :err, meta: t("settings.providers.meta.sync_error"), last_synced_at: nil } if health[:error]

      valid_items = @enable_banking_items&.select(&:session_valid?) || []

      # All items have expired/missing sessions — need re-authorization
      if valid_items.empty?
        return { status: :warn, meta: t("settings.providers.meta.reconsent_required"), last_synced_at: last_synced_at }
      end

      expiring = valid_items.find do |item|
        item.session_expires_at.present? && item.session_expires_at < 7.days.from_now
      end

      if expiring
        days = [ ((expiring.session_expires_at - Time.current) / 1.day).ceil, 1 ].max
        return { status: :warn, meta: t("settings.providers.meta.reconsent_needed", count: days), last_synced_at: last_synced_at }
      end

      return { status: :warn, meta: t("settings.providers.meta.no_recent_sync"), last_synced_at: last_synced_at } if health[:stale]

      if last_synced_at.present?
        { status: :ok, meta: t("settings.providers.meta.last_synced", time: concise_time_ago(last_synced_at)), last_synced_at: last_synced_at }
      else
        { status: :ok, last_synced_at: nil }
      end
    end

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
