# Contract for providers that answer typed questions about a state rather than
# generating text.
#
# Kept out of LlmConcept because these providers cannot produce prose.
# Provider::Registry.preferred_llm_provider assumes full capability of anything
# registered under :llm, and would route chat traffic here.
#
# One #decide call carries one state and many questions, and billing is almost
# entirely for the state — five questions cost 1.31x one against Jev. Batch
# questions into a single call rather than making one call each.
module Provider::ClassificationConcept
  extend ActiveSupport::Concern

  # One typed answer. `value` holds the primitive-specific payload:
  #   choice => the selected criteria key (String)
  #   score  => position on the rubric (Float, 0-indexed against `legend`)
  #   noul   => probability the statement is true (Float, 0.0..1.0)
  #
  # `probabilities` is the full distribution for choice/score and nil for noul.
  Decision = Data.define(:key, :type, :value, :probabilities, :confidence)

  # The answers to one #decide call, with what the call cost.
  DecisionSet = Data.define(:decisions, :model, :usage) do
    def [](key)
      decisions[key.to_s]
    end

    def value_of(key)
      self[key]&.value
    end
  end

  # A categorization carrying the calibrated confidence the provider reported.
  # Responds to #transaction_id and #category_name, so callers written against
  # Provider::LlmConcept::AutoCategorization consume it unchanged. `usage` is
  # per-transaction because this provider spends one request per transaction.
  CategoryDecision = Data.define(:transaction_id, :category_name, :confidence, :probabilities, :usage)

  # Answers `questions` about `state` in a single request, returning a
  # DecisionSet. `state` is a String, Hash or Array; `questions` is a Hash of
  # question key => definition.
  def decide(state:, questions:, model: "", family: nil)
    raise NotImplementedError, "Subclasses must implement #decide"
  end
end
