class RulesController < ApplicationController
  include StreamExtensions

  before_action :set_rule, only: [  :edit, :update, :destroy, :apply, :confirm ]

  def index
    @sort_by = params[:sort_by] || "name"
    @direction = params[:direction] || "asc"

    allowed_columns = [ "name", "updated_at" ]
    @sort_by = "name" unless allowed_columns.include?(@sort_by)
    @direction = "asc" unless [ "asc", "desc" ].include?(@direction)

    @rules = Current.family.rules.includes(conditions: :sub_conditions).order(@sort_by => @direction)

    # Fetch recent rule runs with pagination
    recent_runs_scope = RuleRun
                          .joins(:rule)
                          .where(rules: { family_id: Current.family.id })
                          .recent
                          .includes(:rule)

    @pagy, @recent_runs = pagy(recent_runs_scope, limit: safe_per_page, page_param: :runs_page)

    render layout: "settings"
  end

  def new
    @rule = Current.family.rules.build(
      resource_type: params[:resource_type] || "transaction",
    )

    if params[:name].present?
      @rule.name = params[:name]
      @rule.conditions.build(
        condition_type: "transaction_name",
        operator: "like",
        value: params[:name]
      )
    end

    if params[:action_type].present? && params[:action_value].present?
      @rule.actions.build(
        action_type: params[:action_type],
        value: params[:action_value]
      )
    end
  end

  def create
    @rule = Current.family.rules.build(rule_params)

    if @rule.save
      redirect_to confirm_rule_path(@rule, reload_on_close: true)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def apply
    @rule.update!(active: true)
    @rule.apply_later(ignore_attribute_locks: true)
    redirect_back_or_to rules_path, notice: "#{@rule.resource_type.humanize} rule activated"
  end

  def confirm
    # Compute provider, model, and cost estimation for auto-categorize actions
    if @rule.actions.any? { |a| a.action_type == "auto_categorize" }
      # Use the same provider determination logic as Family::AutoCategorizer
      llm_provider = Provider::Registry.get_provider(:openai)

      if llm_provider
        @selected_model = Provider::Openai.effective_model
        @estimated_cost = LlmUsage.estimate_auto_categorize_cost(
          transaction_count: @rule.affected_resource_count,
          category_count: @rule.family.categories.count,
          model: @selected_model
        )
      end
    end
  end

  def edit
  end

  def update
    if @rule.update(rule_params)
      respond_to do |format|
        format.html { redirect_back_or_to rules_path, notice: "Rule updated" }
        format.turbo_stream { stream_redirect_back_or_to rules_path, notice: "Rule updated" }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @rule.destroy
    redirect_to rules_path, notice: "Rule deleted"
  end

  def destroy_all
    Current.family.rules.destroy_all
    redirect_to rules_path, notice: "All rules deleted"
  end

  def confirm_all
    @rules = Current.family.rules
    @total_affected_count = Rule.total_affected_resource_count(@rules)

    # Compute AI cost estimation if any rule has auto_categorize action
    if @rules.any? { |r| r.actions.any? { |a| a.action_type == "auto_categorize" } }
      llm_provider = Provider::Registry.get_provider(:openai)

      if llm_provider
        @selected_model = Provider::Openai.effective_model
        @estimated_cost = LlmUsage.estimate_auto_categorize_cost(
          transaction_count: @total_affected_count,
          category_count: Current.family.categories.count,
          model: @selected_model
        )
      end
    end
  end

  def apply_all
    ApplyAllRulesJob.perform_later(Current.family)
    redirect_back_or_to rules_path, notice: t("rules.apply_all.success")
  end

  def clear_ai_cache
    ClearAiCacheJob.perform_later(Current.family)
    redirect_to rules_path, notice: t("rules.clear_ai_cache.success")
  end

  private
    def set_rule
      @rule = Current.family.rules.find(params[:id])
    end

    def rule_params
      params.require(:rule).permit(
        :resource_type, :effective_date, :active, :name,
        conditions_attributes: [
          :id, :condition_type, :operator, :value, :_destroy,
          sub_conditions_attributes: [ :id, :condition_type, :operator, :value, :_destroy ]
        ],
        actions_attributes: [
          :id, :action_type, :value, :_destroy
        ]
      )
    end
end
