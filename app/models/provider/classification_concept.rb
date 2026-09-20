# Contract for providers that answer typed questions about a state rather than
# generating text.
#
# Deliberately separate from LlmConcept. A classification provider is not a
# drop-in LLM: Jev cannot produce prose, so it can never satisfy #chat_response
# or #process_pdf. Registering such a provider under the :llm concept would let
# Provider::Registry.preferred_llm_provider — which picks the first provider
# holding credentials and assumes full capability — route chat traffic to
# something that physically cannot serve it.
#
# The primitive is #decide rather than a method per task, because one call
# carries one state and many questions and the provider bills almost entirely
# for the state: measured against Jev, five questions cost 1.31x one question.
# Task-shaped helpers should therefore batch their questions into one #decide
# rather than each making their own call.
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
  # Structurally compatible with Provider::LlmConcept::AutoCategorization — it
  # responds to #transaction_id and #category_name — so existing callers and
  # eval runners consume it unchanged and ignore the extra fields.
  #
  # `usage` is per-transaction rather than per-batch because this provider spends
  # one request per transaction, which is what lets the eval attribute cost to
  # individual samples.
  CategoryDecision = Data.define(:transaction_id, :category_name, :confidence, :probabilities, :usage)

  # Answers `questions` about `state` in a single request.
  #
  # state     - String, Hash or Array describing the thing being decided about
  # questions - Hash of question key => question definition
  #
  # Returns a DecisionSet.
  def decide(state:, questions:, model: "", family: nil)
    raise NotImplementedError, "Subclasses must implement #decide"
  end
end
