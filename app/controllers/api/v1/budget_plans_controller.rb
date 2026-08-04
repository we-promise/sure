# frozen_string_literal: true

module Api
  module V1
    # API v1 endpoint for budget plans — the named, optionally account-scoped
    # budgets a family keeps side by side (e.g. "Personal" vs "Joint", or a
    # test budget observed next to the live one). Monthly budget rows belong
    # to a plan; see Api::V1::BudgetsController's budget_plan_id filter.
    #
    # @example Create an account-scoped plan
    #   POST /api/v1/budget_plans
    #   { "budget_plan": { "name": "Joint", "account_ids": ["<uuid>", "<uuid>"] } }
    #
    class BudgetPlansController < BaseController
      before_action -> { authorize_scope!(:read) }, only: %i[index show]
      before_action -> { authorize_scope!(:read_write) }, only: %i[create update destroy]
      before_action :set_budget_plan, only: %i[show update destroy]

      def index
        plans = family.budget_plans.default_first.includes(:budget_plan_accounts)

        render json: plans.map { |plan| budget_plan_json(plan) }
      end

      def show
        render json: budget_plan_json(@budget_plan)
      end

      def create
        @budget_plan = family.budget_plans.new(name: budget_plan_params[:name])
        return unless assign_accounts(@budget_plan)

        if @budget_plan.save
          render json: budget_plan_json(@budget_plan), status: :created
        else
          render json: { error: @budget_plan.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      def update
        @budget_plan.name = budget_plan_params[:name] if budget_plan_params.key?(:name)
        return unless assign_accounts(@budget_plan)

        if @budget_plan.save
          render json: budget_plan_json(@budget_plan)
        else
          render json: { error: @budget_plan.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      def destroy
        if @budget_plan.destroy
          head :no_content
        else
          render json: { error: @budget_plan.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      private

        def family
          current_resource_owner.family
        end

        def set_budget_plan
          @budget_plan = family.budget_plans.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Budget plan not found" }, status: :not_found
        end

        def budget_plan_params
          params.require(:budget_plan).permit(:name, account_ids: [])
        end

        # Replaces the plan's scoped accounts when the account_ids key is
        # present ([] clears the scope back to all-accounts); leaves the
        # scope untouched when the key is omitted. Ids are re-scoped through
        # the family; unknown ids are a 422, not silently dropped.
        def assign_accounts(plan)
          return true unless budget_plan_params.key?(:account_ids)

          ids = Array(budget_plan_params[:account_ids]).reject(&:blank?).uniq
          accounts = family.accounts.where(id: ids)
          missing = ids - accounts.pluck(:id)

          if missing.any?
            render json: { error: "Unknown account ids: #{missing.join(', ')}" }, status: :unprocessable_entity
            return false
          end

          plan.account_ids = accounts.map(&:id)
          true
        end

        def budget_plan_json(plan)
          {
            id: plan.id,
            name: plan.name,
            slug: plan.slug,
            is_default: plan.is_default,
            # [] means the plan tracks all of the family's accounts.
            account_ids: plan.budget_plan_accounts.map(&:account_id),
            created_at: plan.created_at,
            updated_at: plan.updated_at
          }
        end
    end
  end
end
