class PagesController < ApplicationController
  include Periodable

  # Per-widget dashboard layout guardrails. Deterministic defaults the masonry
  # packer reads; users may override a grow widget's height via presets.
  #   col_span:   "single" | "full" (full spans both columns in 2-col mode)
  #   grow:       true for charts that should fill an allotted height,
  #               false for content-sized widgets (tables, stat grids)
  #   min_height: floor in px
  DASHBOARD_SECTION_LAYOUTS = {
    "cashflow_sankey"    => { col_span: "full",   grow: false, min_height: 384, width_toggle: true },
    "outflows_donut"     => { col_span: "single", grow: false, min_height: 0 },
    "investment_summary" => { col_span: "single", grow: false, min_height: 0, width_toggle: true },
    "net_worth_chart"    => { col_span: "single", grow: true,  min_height: 208, width_toggle: true },
    "balance_sheet"      => { col_span: "single", grow: false, min_height: 0, width_toggle: true }
  }.freeze

  # Selectable height presets (px) for grow widgets.
  DASHBOARD_HEIGHT_PRESETS = { "compact" => 208, "auto" => 288, "tall" => 416 }.freeze
  DEFAULT_HEIGHT_PRESET = "auto"

  skip_authentication only: %i[redis_configuration_error privacy terms]
  before_action :ensure_intro_guest!, only: :intro

  def dashboard
    if Current.user&.ui_layout_intro?
      redirect_to chats_path and return
    end

    @balance_sheet = Current.family.balance_sheet
    @investment_statement = Current.family.investment_statement
    @accounts = Current.user.accessible_accounts.visible.with_attached_logo

    # Use IncomeStatement for all cashflow data (now includes categorized trades)
    income_statement = Current.family.income_statement

    @cashflow_sankey_data = income_statement.cashflow_sankey_data(period: @period)
    @outflows_data = build_outflows_donut_data(income_statement.net_category_totals(period: @period))

    @dashboard_sections = build_dashboard_sections

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.dashboard"), nil ] ]
  end

  def intro
    @breadcrumbs = [ [ t("breadcrumbs.home"), chats_path ], [ t("breadcrumbs.intro"), nil ] ]
  end

  def update_preferences
    if Current.user.update_dashboard_preferences(preferences_params)
      head :ok
    else
      head :unprocessable_entity
    end
  end

  def changelog
    @release_notes = github_provider.fetch_latest_release_notes

    # Fallback if no release notes are available
    if @release_notes.nil?
      @release_notes = {
        avatar: "https://github.com/we-promise.png",
        username: "we-promise",
        name: t("pages.release_notes_unavailable.name"),
        published_at: Date.current,
        body: t("pages.release_notes_unavailable.body_html")
      }
    end

    render layout: "settings"
  end

  def feedback
    render layout: "settings"
  end

  def redis_configuration_error
    render layout: "blank"
  end

  def privacy
    render layout: "blank"
  end

  def terms
    render layout: "blank"
  end

  private
    def preferences_params
      prefs = params.require(:preferences)
      {}.tap do |permitted|
        permitted["collapsed_sections"] = prefs[:collapsed_sections].to_unsafe_h if prefs[:collapsed_sections].respond_to?(:to_unsafe_h)
        permitted["section_order"] = prefs[:section_order] if prefs[:section_order].is_a?(Array)
        permitted["dashboard_section_layout"] = prefs[:dashboard_section_layout].to_unsafe_h if prefs[:dashboard_section_layout].respond_to?(:to_unsafe_h)
      end
    end

    def build_dashboard_sections
      all_sections = [
        {
          key: "cashflow_sankey",
          title: "pages.dashboard.cashflow_sankey.title",
          partial: "pages/dashboard/cashflow_sankey",
          layout: section_layout("cashflow_sankey"),
          locals: { sankey_data: @cashflow_sankey_data, period: @period },
          visible: @accounts.any?,
          collapsible: true
        },
        {
          key: "outflows_donut",
          title: "pages.dashboard.outflows_donut.title",
          partial: "pages/dashboard/outflows_donut",
          layout: section_layout("outflows_donut"),
          locals: { outflows_data: @outflows_data, period: @period },
          visible: @accounts.any? && @outflows_data[:categories].present?,
          collapsible: true
        },
        {
          key: "investment_summary",
          title: "pages.dashboard.investment_summary.title",
          partial: "pages/dashboard/investment_summary",
          layout: section_layout("investment_summary"),
          locals: { investment_statement: @investment_statement, period: @period },
          visible: @accounts.any? && @investment_statement.investment_accounts.any?,
          collapsible: true
        },
        {
          key: "net_worth_chart",
          title: "pages.dashboard.net_worth_chart.title",
          partial: "pages/dashboard/net_worth_chart",
          layout: section_layout("net_worth_chart"),
          locals: { balance_sheet: @balance_sheet, period: @period },
          visible: @accounts.any?,
          collapsible: true
        },
        {
          key: "balance_sheet",
          title: "pages.dashboard.balance_sheet.title",
          partial: "pages/dashboard/balance_sheet",
          layout: section_layout("balance_sheet"),
          locals: { balance_sheet: @balance_sheet },
          visible: @accounts.any?,
          collapsible: true
        }
      ]

      # Order sections according to user preference
      section_order = Current.user.dashboard_section_order
      ordered_sections = section_order.map do |key|
        all_sections.find { |s| s[:key] == key }
      end.compact

      # Add any new sections that aren't in the saved order (future-proofing)
      all_sections.each do |section|
        ordered_sections << section unless ordered_sections.include?(section)
      end

      ordered_sections
    end

    # Resolves a section's layout guardrails, applying the user's height preset
    # override (falling back to the deterministic default) for grow widgets.
    def section_layout(key)
      base = DASHBOARD_SECTION_LAYOUTS.fetch(key, { col_span: "single", grow: false, min_height: 0, width_toggle: false })
      preset = Current.user.dashboard_section_height(key)
      preset = DEFAULT_HEIGHT_PRESET unless DASHBOARD_HEIGHT_PRESETS.key?(preset)

      col_span = base[:col_span]
      if base[:width_toggle]
        user_span = Current.user.dashboard_section_width(key)
        col_span = user_span if %w[single full].include?(user_span)
      end

      base.merge(col_span: col_span, height_preset: preset, height_px: DASHBOARD_HEIGHT_PRESETS.fetch(preset))
    end

    def github_provider
      Provider::Registry.get_provider(:github)
    end

    def build_outflows_donut_data(net_totals)
      currency_symbol = Money::Currency.new(net_totals.currency).symbol
      total = net_totals.total_net_expense

      categories = net_totals.net_expense_categories
        .reject { |ct| ct.total.zero? }
        .sort_by { |ct| -ct.total }
        .map do |ct|
          {
            id: ct.category.id,
            name: ct.category.name,
            amount: ct.total.to_f.round(2),
            currency: ct.currency,
            percentage: ct.weight.round(1),
            color: ct.category.color.presence || Category::UNCATEGORIZED_COLOR,
            icon: ct.category.lucide_icon,
            clickable: !ct.category.other_investments?
          }
        end

      { categories: categories, total: total.to_f.round(2), currency: net_totals.currency, currency_symbol: currency_symbol }
    end

    def ensure_intro_guest!
      return if Current.user&.guest?

      redirect_to root_path, alert: t("pages.intro.not_authorized", default: "Intro is only available to guest users.")
    end
end
