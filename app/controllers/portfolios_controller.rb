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
    # Allow-list, mirroring ReportsController#preferences_params: only the two
    # portfolio keys survive, so a payload naming another page's preference
    # (or an arbitrary user attribute) is dropped rather than written.
    def preferences_params
      @preferences_params ||= begin
        prefs = params.require(:preferences)

        {}.tap do |permitted|
          # A collapsed set is an object of key => flag; anything else (a
          # bare string, an array) is not the contract and is dropped rather
          # than raised on.
          # Only the registry's own section keys are stored, in both
          # shapes: anything else would sit in the user's preferences for
          # good, and the registry would never read it.
          known = Portfolio::SectionRegistry::KEYS
          collapsed = prefs[:portfolio_collapsed_sections]
          if collapsed.respond_to?(:to_unsafe_h)
            permitted["portfolio_collapsed_sections"] = collapsed.to_unsafe_h
              .slice(*known)
              .transform_values { |v| ActiveModel::Type::Boolean.new.cast(v) == true }
          end

          # Deduplicated, first occurrence wins: the registry renders one
          # section per saved key, so a repeated key would render it twice.
          if prefs[:portfolio_section_order].present?
            permitted["portfolio_section_order"] = Array(prefs[:portfolio_section_order]).map(&:to_s).uniq & known
          end
        end
      end
    end
end
