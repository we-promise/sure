# frozen_string_literal: true

class Api::V1::BudgetCategoriesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :refresh_rollover_chains
  before_action :set_budget_category, only: :show

  def index
    budget_categories_query = apply_filters(budget_categories_scope)
      .order("budgets.start_date DESC", "categories.name ASC")
    @per_page = safe_per_page_param

    @pagy, @budget_categories = pagy(
      budget_categories_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  private

    def set_budget_category
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @budget_category = budget_categories_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
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
      shared_with_me = BudgetShare.where(viewer_id: current_resource_owner.id).pluck(:owner_id)
      [ nil, current_resource_owner.id, *shared_with_me ]
    end

    def apply_filters(query)
      if params[:budget_id].present?
        raise InvalidFilterError, "budget_id must be a valid UUID" unless valid_uuid?(params[:budget_id])

        query = query.where(budget_id: params[:budget_id])
      end

      if params[:category_id].present?
        raise InvalidFilterError, "category_id must be a valid UUID" unless valid_uuid?(params[:category_id])

        query = query.where(category_id: params[:category_id])
      end

      query = query.where("budgets.start_date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("budgets.end_date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      query
    end
end
