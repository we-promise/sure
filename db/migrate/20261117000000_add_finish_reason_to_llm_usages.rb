class AddFinishReasonToLlmUsages < ActiveRecord::Migration[8.1]
  def change
    # The answering request of a call carries why the model stopped
    # (RubyLLM's finish reason). Written by Ai::Instrumentation::UsageSubscriber
    # from the call's `.ai` event; failed requests have none.
    add_column :llm_usages, :finish_reason, :string
  end
end
