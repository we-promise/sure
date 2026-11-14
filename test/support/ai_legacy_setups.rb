# The supported AI setups, for the tests that compare Ai::LegacyEnvConfig and the router with the
# resolution of the code not yet on the router (test/architecture/ai_config_test,
# ai_agreement_test). C1-C9 are one setup each; M1-M5 mix them.
module AiLegacySetups
  # Cleared in every setup, so the host's environment can't leak in.
  CONTROLLED = %w[
    OPENAI_ACCESS_TOKEN OPENAI_URI_BASE OPENAI_MODEL ANTHROPIC_ACCESS_TOKEN ANTHROPIC_API_KEY ANTHROPIC_BASE_URL
    ANTHROPIC_MODEL LLM_PROVIDER JEV_API_KEY JEV_ENDPOINT JEV_MODEL CATEGORIZATION_PROVIDER VECTOR_STORE_PROVIDER
    ASSISTANT_TYPE EMBEDDING_URI_BASE EMBEDDING_ACCESS_TOKEN EMBEDDING_MODEL EXTERNAL_ASSISTANT_URL
    EXTERNAL_ASSISTANT_TOKEN EXTERNAL_ASSISTANT_MODEL EXTERNAL_ASSISTANT_ALLOWED_EMAILS
  ].freeze

  OPENAI = { "OPENAI_ACCESS_TOKEN" => "sk-test" }.freeze
  ANTHROPIC = { "ANTHROPIC_API_KEY" => "sk-ant-test" }.freeze

  # id => [label, ENV, Setting values, family attributes]
  SETUPS = {
    "C1" => [ "nothing configured", {}, {}, {} ],
    "C2" => [ "OpenAI key", OPENAI, {}, {} ],
    "C3" => [ "Anthropic key only, LLM_PROVIDER unset", ANTHROPIC, {}, {} ],
    "C4" => [ "Anthropic key only, LLM_PROVIDER=anthropic", ANTHROPIC.merge("LLM_PROVIDER" => "anthropic"), {}, {} ],
    "C5" => [ "OpenAI-compatible URL and model (Ollama)",
              { "OPENAI_ACCESS_TOKEN" => "ollama", "OPENAI_URI_BASE" => "http://ollama:11434/v1", "OPENAI_MODEL" => "qwen3:8b" }, {}, {} ],
    "C6" => [ "OpenAI-compatible URL, model left blank",
              { "OPENAI_ACCESS_TOKEN" => "ollama", "OPENAI_URI_BASE" => "http://ollama:11434/v1" }, {}, {} ],
    "C7" => [ "both keys, LLM_PROVIDER=anthropic", OPENAI.merge(ANTHROPIC).merge("LLM_PROVIDER" => "anthropic"), {}, {} ],
    "C8" => [ "OpenAI key, OPENAI_MODEL=o4-mini", OPENAI.merge("OPENAI_MODEL" => "o4-mini"), {}, {} ],
    "C9" => [ "Jev only (CATEGORIZATION_PROVIDER=jev)", { "JEV_API_KEY" => "jev-test", "CATEGORIZATION_PROVIDER" => "jev" }, {}, {} ],
    "M1" => [ "OpenAI and Jev keys, the instance chose Jev", OPENAI.merge("JEV_API_KEY" => "jev-test"), { categorization_provider: "jev" }, {} ],
    "M2" => [ "both keys, LLM_PROVIDER=anthropic, an embedding server",
              OPENAI.merge(ANTHROPIC).merge("LLM_PROVIDER" => "anthropic", "EMBEDDING_URI_BASE" => "http://ollama:11434/v1",
                                            "EMBEDDING_MODEL" => "nomic-embed-text"), {}, {} ],
    "M3" => [ "configured in Settings only", {},
              { openai_access_token: "sk-setting", openai_uri_base: "https://gateway.example.test/v1", openai_model: "gpt-4.1-mini" }, {} ],
    "M4" => [ "OpenAI key and an external assistant, external mode",
              OPENAI.merge("ASSISTANT_TYPE" => "external", "EXTERNAL_ASSISTANT_URL" => "https://agent.example.test/v1",
                           "EXTERNAL_ASSISTANT_TOKEN" => "agent-token"), {}, {} ],
    "M5" => [ "OpenAI key, assistant type mcp_only", OPENAI.merge("ASSISTANT_TYPE" => "mcp_only"), {}, {} ]
  }.freeze

  # Runs the block in the setup, against today's code and Ai::LegacyEnvConfig.
  def in_ai_setup(id, family:, &block)
    _label, env, settings, family_attributes = SETUPS.fetch(id)
    settings.each { |field, value| Setting.public_send("#{field}=", value) }
    family.update!(family_attributes) if family_attributes.any?
    with_env_overrides(CONTROLLED.index_with { nil }.merge(env), &block)
  ensure
    settings.each_key { |field| Setting.public_send("#{field}=", nil) }
    Setting.clear_cache
  end
end
