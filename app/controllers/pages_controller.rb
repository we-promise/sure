class PagesController < ApplicationController
  include Periodable

  skip_authentication only: :redis_configuration_error

  def dashboard
    @balance_sheet = Current.family.balance_sheet
    @investment_statement = Current.family.investment_statement
    @accounts = Current.family.accounts.visible.with_attached_logo
    @include_investments = params[:include_investments] == "true"

    # Use the unified CashflowStatement model
    @cashflow_statement = Current.family.cashflow_statement(period: @period)

    family_currency = Current.family.currency
    currency_symbol = Money::Currency.new(family_currency).symbol

    # Build sankey data from CashflowStatement
    @cashflow_sankey_data = @cashflow_statement.sankey_data(
      currency_symbol: currency_symbol,
      include_investing: @include_investments,
      include_financing: true # Always show financing (loan/cc payments)
    )

    # Build outflows donut data from operating activities
    @outflows_data = build_outflows_donut_data(@cashflow_statement.operating_activities)

    @breadcrumbs = [ [ "Home", root_path ], [ "Dashboard", nil ] ]
  end

  def changelog
    @release_notes = github_provider.fetch_latest_release_notes

    # Fallback if no release notes are available
    if @release_notes.nil?
      @release_notes = {
        avatar: "https://github.com/we-promise.png",
        username: "we-promise",
        name: "Release notes unavailable",
        published_at: Date.current,
        body: "<p>Unable to fetch the latest release notes at this time. Please check back later or visit our <a href='https://github.com/we-promise/sure/releases' target='_blank'>GitHub releases page</a> directly.</p>"
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

  private
    def github_provider
      Provider::Registry.get_provider(:github)
    end

    def build_outflows_donut_data(operating_activities)
      currency_symbol = Money::Currency.new(operating_activities.family.currency).symbol
      total = operating_activities.outflows

      # Only include top-level categories with non-zero amounts
      categories = operating_activities.expenses_by_category
        .reject { |ct| ct.category.respond_to?(:parent_id) && ct.category.parent_id.present? }
        .reject { |ct| ct.total.zero? }
        .sort_by { |ct| -ct.total }
        .map do |ct|
          {
            id: ct.category.id,
            name: ct.category.name,
            amount: ct.total.to_f.round(2),
            percentage: ct.weight.round(1),
            color: ct.category.color.presence || Category::UNCATEGORIZED_COLOR,
            icon: ct.category.respond_to?(:lucide_icon) ? ct.category.lucide_icon : "circle-dashed"
          }
        end

      { categories: categories, total: total.to_f.round(2), currency_symbol: currency_symbol }
    end
end
