module Assistant::TokenBudget
  module_function

  # Shared resolution of the model's context window so prompt assembly and the
  # provider layer agree on the same number. Precedence: ENV > Setting >
  # default, matching Provider::Openai's historical behavior.
  DEFAULT_CONTEXT_WINDOW = 2048

  def context_window
    from_env = ENV["LLM_CONTEXT_WINDOW"].to_s.strip.to_i
    return from_env if from_env.positive?

    from_setting = Setting.llm_context_window.to_i
    return from_setting if from_setting.positive?

    DEFAULT_CONTEXT_WINDOW
  end

  # Below this, per-request context like account rosters is collapsed to
  # counts so the volatile tail of the system prompt stays small.
  SMALL_CONTEXT_THRESHOLD = 4096

  def small_context?
    context_window < SMALL_CONTEXT_THRESHOLD
  end
end
