# The prompt a generation sends (section 8.3). Every prompt is a folder in app/prompts:
#
#   app/prompts/<name>/instructions.txt.erb   the system prompt
#   app/prompts/<name>/input.txt.erb          the user message, filled with the request's items
#
# rendered by RubyLLM.render_prompt, with partials under app/prompts/shared/. Which prompt runs is
# the first that applies:
#
#   1. the family's override, for the features a family can override, which replaces the
#      instructions as plain text (never compiled: ERB runs Ruby, and a family admin isn't
#      trusted with the server);
#   2. the route entry's `prompt:`, set by the instance admin;
#   3. the feature's default folder.
#
# For whichever folder was chosen, `<part>.<locale>.txt.erb` is used when it exists.
class Ai::Prompt
  ROOT = Rails.root.join("app/prompts")

  # Features whose instructions a family can override, and the Family::AiPromptable key: today's
  # one key per provider until the keys collapse to one per feature (section 8.3).
  OVERRIDES = {
    categorize: { anthropic: :categorizer_anthropic, compatible: :categorizer_openai },
    detect_merchants: { anthropic: :merchant_anthropic, compatible: :merchant_openai }
  }.freeze

  Rendered = Data.define(:name, :instructions, :input, :locale, :override) do
    # What instrumentation and Ai::Comparison record about the prompt that ran.
    def to_event = { name:, locale:, override: }.compact
  end

  def self.for(feature, default:, route:, family:, locale:, locals:)
    new(feature, default:, route:, family:, locale:).render(**locals)
  end

  def self.exists?(name) = ROOT.join(name.to_s, "instructions.txt.erb").exist?

  def initialize(feature, default:, route:, family:, locale:)
    @feature = feature.to_sym
    @route = route
    @name = (route&.prompt.presence || default).to_s
    @family = family
    @locale = locale&.to_s
    raise ArgumentError, "no prompt folder app/prompts/#{@name}" unless self.class.exists?(@name)
  end

  def render(**locals)
    override = override_text
    Rendered.new(
      name: @name,
      instructions: override || part("instructions", **locals),
      input: part("input", **locals),
      locale: localized?("instructions") ? @locale : nil,
      override: override.present? || nil
    )
  end

  private
    def override_text
      key = OVERRIDES.dig(@feature, @route&.endpoint&.protocol || :compatible)
      key && @family&.ai_prompt(key)
    end

    def part(part, **locals)
      file = localized?(part) ? "#{part}.#{@locale}" : part
      RubyLLM.render_prompt("#{@name}/#{file}", **locals)
    end

    def localized?(part)
      @locale.present? && ROOT.join(@name, "#{part}.#{@locale}.txt.erb").exist?
    end
end
