# Every family AI setting and the methods that read them (ai-plumbing-redesign.md, section 6), kept
# out of family.rb, which many open PRs touch. Family::AiPromptable keeps the prompt overrides.
#
# Until PR 7, the ENV overrides here still win over the family's columns, as they always have.
module Family::AiSettings
  extend ActiveSupport::Concern

  # `mcp_only` removes the in-app assistant (chat, sidebar, chat-seeding
  # buttons) without touching MCP: /mcp serves the same tool registry to
  # external agents whatever this says. "Off" stays free for a future
  # no-LLM-at-all switch; categorization still runs under `mcp_only`.
  ASSISTANT_TYPES = %w[builtin external mcp_only].freeze

  # Which provider categorizes this family's transactions. Family-level rather
  # than a global Setting because it decides whose transaction descriptions get
  # sent to a third party — the same reason assistant_type lives here.
  CATEGORIZATION_PROVIDERS = %w[llm jev].freeze

  included do
    validates :assistant_type, inclusion: { in: ASSISTANT_TYPES }
    validates :categorization_provider, inclusion: { in: CATEGORIZATION_PROVIDERS }
    validates :categorization_confidence_threshold,
              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :categorization_shadow_rate,
              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  end

  # Single definition of the ENV-over-column precedence, so the resolver and the
  # settings UI can never disagree about which provider is actually in force.
  def effective_categorization_provider
    ENV["CATEGORIZATION_PROVIDER"].presence || categorization_provider
  end

  # ENV-over-column precedence for the assistant, same shape as the provider
  # above. Unknown ENV values pass through; callers treat them as builtin.
  def effective_assistant_type
    ENV["ASSISTANT_TYPE"].presence || assistant_type.presence || "builtin"
  end

  def assistant_enabled?
    effective_assistant_type != "mcp_only"
  end

  # The provider that will actually categorize this family's transactions,
  # falling back to the LLM path when Jev is unselected or unconfigured.
  # Credentials alone never select Jev; the family has to choose it, because
  # this decides whose transaction descriptions reach a third party.
  #
  # Anything naming the provider calls this, including the rule confirmation
  # screen's cost estimate, or it quotes a provider that will not run. Views
  # call it while rendering, so it writes nothing itself; a caller that runs
  # categorization passes a block to hear why Jev could not be built.
  def resolved_categorization_provider(&on_jev_error)
    jev = configured_jev_provider(&on_jev_error) if effective_categorization_provider == "jev"

    # Honors Setting.llm_provider (#2113); Provider::Anthropic gained
    # auto_categorize in #1984, so either LLM provider can serve this.
    jev || Provider::Registry.preferred_llm_provider
  end

  def categorization_model_name
    provider = resolved_categorization_provider
    return unless provider

    case provider
    when Provider::Jev then Provider::Jev.effective_model
    when Provider::Anthropic then Provider::Anthropic.effective_model
    else Provider::Openai.effective_model
    end
  end

  # Answers below this confidence are not applied. Zero applies everything and
  # is the default. Only providers reporting calibrated confidence can be gated;
  # the LLM providers return a bare category name. Clamped because the ENV
  # override bypasses both the column validation and the DB check constraint.
  def effective_categorization_confidence_threshold
    (ENV["CATEGORIZATION_CONFIDENCE_THRESHOLD"].presence || categorization_confidence_threshold).to_f.clamp(0.0, 1.0)
  end

  # Fraction of categorization runs that also ask the provider not in use, for
  # comparison only. Zero disables it. Doubles spend on the runs it samples, so
  # it is sampled rather than all-or-nothing. Clamped because `rand < rate` on
  # an unbounded override samples every run.
  def effective_categorization_shadow_rate
    (ENV["CATEGORIZATION_SHADOW_RATE"].presence || categorization_shadow_rate).to_f.clamp(0.0, 1.0)
  end

  # The provider to run alongside the one in use, for comparison. Symmetric —
  # returns whichever of the two is not selected, so either can be trialled
  # against the other without a second mechanism.
  def shadow_categorization_provider(&on_jev_error)
    if effective_categorization_provider == "jev"
      Provider::Registry.preferred_llm_provider
    else
      configured_jev_provider(&on_jev_error)
    end
  end

  # An external assistant answers this family's chats. Reads today's assistant type until chat
  # mode gets its own column (PR 7).
  def chat_mode_external?
    effective_assistant_type == "external"
  end

  private
    # Returns Jev, or nil when it cannot be built. The registry constructs a fresh
    # Provider::Jev per lookup and its constructor rejects a cleartext endpoint,
    # which JEV_ENDPOINT can set without passing the settings form's check.
    def configured_jev_provider
      Provider::Registry.get_provider(:jev)
    rescue Provider::Error => error
      yield error if block_given?
      nil
    end
end
