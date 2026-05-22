module NavigationHelper
  def main_nav_items(intro_mode:)
    return intro_nav_items if intro_mode

    items = [
      { name: t("layouts.application.nav.home"), path: root_path, icon: "pie-chart", icon_custom: false, active: page_active?(root_path) },
      { name: t("layouts.application.nav.transactions"), path: transactions_path, icon: "credit-card", icon_custom: false, active: page_active?(transactions_path) },
      { name: t("layouts.application.nav.reports"), path: reports_path, icon: "chart-bar", icon_custom: false, active: page_active?(reports_path) },
      { name: t("layouts.application.nav.budgets"), path: budgets_path, icon: "map", icon_custom: false, active: page_active?(budgets_path) },
      { name: t("layouts.application.nav.assistant"), path: chats_path, icon: "icon-assistant", icon_custom: true, active: page_active?(chats_path), mobile_only: true }
    ]

    items.reject { |item| item[:module] && !module_enabled?(item[:module]) }
  end

  def mobile_nav_items(intro_mode:)
    main_nav_items(intro_mode: intro_mode)
  end

  def desktop_nav_items(intro_mode:)
    main_nav_items(intro_mode: intro_mode).reject { |item| item[:mobile_only] }
  end

  private
    def intro_nav_items
      [
        { name: t("layouts.application.nav.home"), path: chats_path, icon: "home", icon_custom: false, active: page_active?(chats_path) },
        { name: "Intro", path: intro_path, icon: "sparkles", icon_custom: false, active: page_active?(intro_path) }
      ]
    end
end
