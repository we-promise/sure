# frozen_string_literal: true

class Api::V1::BudgetCategoriesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_search, only: :index
  before_action :refresh_rollover_chains
  before_action :set_budget_category, only: :show

  def index
    @per_page = safe_per_page_param

    @pagy, @budget_categories = pagy(
      @search.budget_categories_scope.order("budgets.start_date DESC", "categories.name ASC"),
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  private

    def set_search
      @search = BudgetCategory::Search.new(
        budget_categories_scope,
        filters: {
          budget_id: uuid_filter_param(:budget_id),
          category_id: uuid_filter_param(:category_id),
          start_date: date_filter_param(:start_date),
          end_date: date_filter_param(:end_date)
        }
      )
    end

    def set_budget_category
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @budget_category = budget_categories_scope.find(params[:id])
    end

    # `rolled_over_amount` is materialized, and the web pages that show it
    # recompute on the way in — every one of them goes through
    # Budget.find_or_bootstrap. This endpoint reads the column straight, so
    # without this it is the one surface that can serve a carry left stale by
    # a sync or a recategorisation touching an earlier month.
    #
    # A read that writes is a smell, but the alternative is recomputing on
    # every transaction change, which is the cost this design deliberately
    # refused: the chain is walked per family, and for a family that never
    # turned rollover on the calculator's leading EXISTS makes it one query
    # that writes nothing. Same bargain the budget page already makes, applied
    # to the surface that was missed.
    def refresh_rollover_chains
      visible_owner_ids.each do |owner_id|
        Budget::RolloverCalculator.new(
          family: current_resource_owner.family,
          user: owner_id && User.find_by(id: owner_id)
        ).recompute!
      end
    end

    def budget_categories_scope
      BudgetCategory
        .joins(:budget, :category)
        .where(budgets: { family_id: current_resource_owner.family_id, user_id: visible_owner_ids })
        .includes({ budget: { budget_categories: { category: :parent } } }, category: :parent)
    end

    def visible_owner_ids
      @visible_owner_ids ||= Budget.visible_owner_ids(current_resource_owner)
    end
end
