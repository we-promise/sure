# Every family AI setting and the methods that read them, kept out of family.rb.
# Family::AiPromptable keeps the prompt overrides.
#
# The ENV overrides here win over the family's columns.
module Family::AiSettings
  extend ActiveSupport::Concern

  # `mcp_only` removes the in-app assistant (chat, sidebar, chat-seeding
  # buttons) without touching MCP: /mcp serves the same tool registry to
  # external agents whatever this says. "Off" stays free for a future
  # no-LLM-at-all switch; categorization still runs under `mcp_only`.
  ASSISTANT_TYPES = %w[builtin external mcp_only].freeze

  included do
    validates :assistant_type, inclusion: { in: ASSISTANT_TYPES }
    validates :categorization_confidence_threshold,
              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :categorization_shadow_rate,
              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  end

  # ENV-over-column precedence for the assistant. Unknown ENV values pass through;
  # callers treat them as builtin.
  def effective_assistant_type
    ENV["ASSISTANT_TYPE"].presence || assistant_type.presence || "builtin"
  end

  def assistant_enabled?
    effective_assistant_type != "mcp_only"
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

  # An external assistant answers this family's chats, read from the assistant type.
  def chat_mode_external?
    effective_assistant_type == "external"
  end
end
