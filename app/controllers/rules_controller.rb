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
        format.html { redirect_back_or_to rules_path, notice: t(".success") }
        format.turbo_stream { stream_redirect_back_or_to rules_path, notice: t(".success") }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @rule.destroy
    redirect_to rules_path, notice: t(".success")
  end

  def destroy_all
    Current.family.rules.destroy_all
    redirect_to rules_path, notice: t(".success")
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
    enqueue_ai_cache_reset
    redirect_to rules_path, notice: t("rules.clear_ai_cache.success")
  end

  private
    # The reset itself happens in a background job, so an enqueue that never
    # lands looks exactly like a job that ran and found nothing. Logging the
    # request separately from the job's own "started" entry tells those apart.
    def enqueue_ai_cache_reset
      perform_ai_cache_reset_later

      DebugLogEntry.capture(
        category: ClearAiCacheJob::DEBUG_CATEGORY,
        level: "info",
        message: "AI cache reset requested from the rules page",
        source: self.class.name,
        family: Current.family,
        user: Current.user
      )
    end

    # Split out so the rescue below covers only the enqueue it reports on.
    # Anything that runs after the job is safely queued — the request log above,
    # the redirect — is then structurally incapable of being recorded as an
    # enqueue failure and retried, without that resting on the internals of
    # whatever those later steps happen to call.
    def perform_ai_cache_reset_later
      attempted_job = nil
      enqueued = ClearAiCacheJob.perform_later(Current.family) { |job| attempted_job = job }

      # perform_later turns an ActiveJob::EnqueueError — or an enqueue aborted by
      # a callback — into a false return rather than raising it, so the return
      # value is the only signal that the reset never reached the queue. The
      # yielded job carries the underlying error when there was one.
      return if enqueued

      raise attempted_job&.enqueue_error || ActiveJob::EnqueueError.new("ClearAiCacheJob was not enqueued")
    rescue => e
      DebugLogEntry.capture(
        category: ClearAiCacheJob::DEBUG_CATEGORY,
        level: "error",
        message: "AI cache reset could not be enqueued: #{e.class}: #{e.message}",
        source: self.class.name,
        family: Current.family,
        user: Current.user,
        metadata: { error_class: e.class.name, error_message: e.message }
      )
      raise
    end

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
