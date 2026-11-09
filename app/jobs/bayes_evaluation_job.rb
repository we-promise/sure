# Runs Settings → Classifier's "Test my settings", "Find best settings"
# (which shows each change it tries) or the test after "Reset to defaults":
# action is one of Family::BayesEvaluation::ACTIONS. Not on an ai_* queue:
# it needs no provider, so the chat reservation shouldn't hold it back.
class BayesEvaluationJob < ApplicationJob
  queue_as :low_priority

  def perform(family, action: "test")
    settings = family.bayes_settings_object
    evaluation = begin
      Family::BayesEvaluation.new(family, settings: settings).run!(action: action) do |changes|
        Family::BayesEvaluation.mark_running!(family)
        trying = I18n.t("settings.classifiers.evaluation.trying", changes: changes.map { |key, value|
          I18n.t("settings.classifiers.evaluation.change", setting: I18n.t("settings.classifiers.#{Family::BayesEvaluation.section_for(key)}.#{key}"),
                                                           value: Family::BayesEvaluation.value_label(key, value))
        }.join("; "))
        Turbo::StreamsChannel.broadcast_update_to(family, target: "classifier_evaluation_progress", html: ERB::Util.html_escape(trying))
      end
    rescue
      # Back to the last result, so the page isn't left on "Testing…".
      broadcast_panel(family, Family::BayesEvaluation.cached(family), settings)
      raise
    end

    broadcast_panel(family, evaluation, settings)
  end

  private
    def broadcast_panel(family, evaluation, settings)
      Turbo::StreamsChannel.broadcast_replace_to(
        family,
        target: "classifier_evaluation",
        partial: "settings/classifiers/evaluation",
        locals: { evaluation: evaluation, settings: settings, running: false, weight: Family::BayesEvaluation.weight(family) }
      )
    end
end
