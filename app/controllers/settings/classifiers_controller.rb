class Settings::ClassifiersController < ApplicationController
  layout "settings"

  before_action :require_admin!

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.classifier"), nil ]
    ]
    @settings = Current.family.bayes_settings_object
    @categories = Current.family.categories.alphabetically_by_hierarchy
    @evaluation = Family::BayesEvaluation.cached(Current.family)
    @evaluation_running = Family::BayesEvaluation.running?(Current.family)
    @weight = Family::BayesEvaluation.weight(Current.family)
    @rules_active = Family::CLASSIFIER_ACTION_TYPES.index_with { |action_type| Current.family.classifier_rule_active?(action_type) }
    @add_rule = params[:add_rule].presence_in(Family::CLASSIFIER_ACTION_TYPES)
    @add_rule = nil if @add_rule && Current.family.classifier_rules(@add_rule).exists?
  end

  # Each section of the page is its own auto-submitting form, so only that
  # section's fields arrive; the rest of the stored settings are kept.
  def update
    if params[:reset].present?
      Current.family.update!(bayes_settings: {})
      return start_evaluation("reset")
    end

    changes = settings_params.to_h
    changes[:excluded_category_ids] = excluded_category_ids if params.key?(:category_filter)
    Current.family.update_bayes_settings!(changes) if changes.any?

    redirect_to settings_classifier_path
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_classifier_path, alert: e.record.errors.full_messages.to_sentence
  end

  # The matcher's or Bayes' switch, in step with its rule on the Rules page.
  # Turning on one whose rule was deleted asks whether to add it again.
  def rule
    action_type = classifier_action_type
    active = params[:active] == "1"
    if active && !Current.family.classifier_rules(action_type).exists?
      return redirect_to settings_classifier_path(add_rule: action_type)
    end

    Current.family.set_classifier_rule_active!(action_type, active)
    redirect_to settings_classifier_path
  end

  def add_rule
    action_type = classifier_action_type
    Current.family.add_classifier_rule!(action_type)
    redirect_to settings_classifier_path, notice: t(".success", name: Family.classifier_rule_name(action_type))
  end

  def run
    BayesCategorizeJob.perform_later(Current.family)
    redirect_to settings_classifier_path, notice: t(".success")
  end

  def clear_locks
    ClearBayesLocksJob.perform_later(Current.family)
    redirect_to settings_classifier_path, notice: t(".success")
  end

  def evaluate
    start_evaluation("test")
  end

  def find_best
    start_evaluation("find_best")
  end

  # The cost of a mistake saves as it changes, picking the bold rows shown
  # and applied, so a reload (e.g. after Apply) keeps it.
  def remember_weight
    Family::BayesEvaluation.remember_weight!(Current.family, params[:weight])

    redirect_to settings_classifier_path(anchor: "classifier_evaluation")
  end

  # Saves what "Find best settings" found, at the threshold for the chosen
  # cost of a mistake, and the matcher's best cutoff, number agreeing and
  # similarity for that cost, and tests them; unless the settings changed since.
  def apply_best
    family = Current.family
    evaluation = Family::BayesEvaluation.cached(family)
    settings = family.bayes_settings_object
    unless evaluation&.dig("best") && evaluation["digest"] == settings.digest
      return redirect_to settings_classifier_path(anchor: "classifier_evaluation")
    end

    weight = Family::BayesEvaluation.weight(family)
    changes = Family::BayesEvaluation.apply_changes(evaluation, settings, weight)
    return redirect_to settings_classifier_path(anchor: "classifier_evaluation") if changes.empty?

    family.update_bayes_settings!(changes)
    start_evaluation("test")
  end

  private
    # One run at a time: a second would overwrite the first's result.
    def start_evaluation(action)
      if Family::BayesEvaluation.start_running!(Current.family)
        BayesEvaluationJob.perform_later(Current.family, action: action)
      end

      redirect_to settings_classifier_path(anchor: "classifier_evaluation")
    end

    def classifier_action_type
      params.require(:action_type).presence_in(Family::CLASSIFIER_ACTION_TYPES) || raise(ActionController::BadRequest)
    end

    def settings_params
      scalar_keys = Family::BayesSettings::DEFAULTS.reject { |_, default| default.is_a?(Array) }.keys
      params.fetch(:bayes_settings, {}).permit(*scalar_keys)
    end

    # The checklist submits what stays checked. Its cascade submits a parent
    # only while every subcategory is checked, so a parent with some children
    # checked isn't excluded itself; its unchecked children are.
    def excluded_category_ids
      included = Array(params[:included_category_ids]).map(&:to_s)
      categories = Current.family.categories.pluck(:id, :parent_id).map { |id, parent_id| [ id.to_s, parent_id&.to_s ] }
      partly_checked_parents = categories.filter_map { |id, parent_id| parent_id if included.include?(id) }
      categories.map(&:first) - included - partly_checked_parents
    end
end
