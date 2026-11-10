class PortfoliosController < ApplicationController
  # Registered before Periodable's set_period, so a request the gate turns
  # away never saves its `period` param as the user's default.
  before_action :require_preview_features!

  include Periodable

  def show
    # `as_of` is captured once and passed down, so every section that takes a
    # date reads the same one and the partials stay pure (no Date.current /
    # Current.family lookups of their own).
    @as_of = Date.current
    @statement = Current.family.investment_statement(user: Current.user)
    @sections = Portfolio::SectionRegistry.new(
      statement: @statement,
      period: @period,
      as_of: @as_of,
      user: Current.user
    ).sections

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.portfolio"), nil ] ]
  end

  def update_preferences
    # `require` passes a scalar through, and indexing a String by key raises,
    # so a body whose `preferences` is not an object is refused here.
    return head :bad_request unless params[:preferences].is_a?(ActionController::Parameters)

    if Current.user.update_section_preferences(
      "portfolio",
      order: preferences_params["portfolio_section_order"],
      collapsed: preferences_params["portfolio_collapsed_sections"]
    )
      head :ok
    else
      head :unprocessable_entity
    end
  end

  private
    # Allow-list: only the two portfolio keys, and within them only the
    # registry's own section keys, so nothing is stored that the registry
    # would never read. User#update_section_preferences drops any value that
    # is not an array of keys or a hash of flags.
    def preferences_params
      @preferences_params ||= begin
        prefs = params.require(:preferences)
        known = Portfolio::SectionRegistry::KEYS
        order = prefs[:portfolio_section_order]
        collapsed = prefs[:portfolio_collapsed_sections]

        {
          "portfolio_section_order" => (order.map(&:to_s) & known if order.is_a?(Array)),
          "portfolio_collapsed_sections" => (collapsed.to_unsafe_h.slice(*known) if collapsed.respond_to?(:to_unsafe_h))
        }
      end
    end
end
