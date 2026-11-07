module OnboardingChoices
  extend ActiveSupport::Concern

  STARTING_TOOLS = %w[
    quicken_classic quicken_simplifi monarch_money ynab firefly_iii actual_budget
    maybe lunch_money copilot_money pocketsmith gnucash money_manager_ex banktivity
    moneywiz empower mint spreadsheets bank_app paper nothing_yet other
  ].freeze
  ONBOARDING_AI_MODES = %w[none builtin external].freeze

  included do
    store_accessor :preferences, :starting_tools, :starting_tool_other, :onboarding_ai_mode
    def onboarding_ai_mode
      super || "none"
    end

    before_validation :normalize_starting_tools
    before_save :apply_onboarding_ai_choice
    validate :validate_starting_tools
    validates :starting_tool_other, length: { maximum: 60 }, allow_nil: true
    validates :onboarding_ai_mode, inclusion: { in: ONBOARDING_AI_MODES }, allow_nil: true
  end

  # The choice controls this user's assistant, not family automation or providers.
  # Serialize first-family completion and store its claim in the same transaction.
  def update_onboarding_choices(attributes)
    intent = nil
    saved = false
    family.with_lock do
      with_lock do
        initial_completion = admin? && onboarded_at.nil? && set_onboarding_goals_at.nil? &&
          family.initial_onboarding_ai_mode.nil? &&
          family.users.order(:created_at, :id).pick(:id) == id &&
          !family.invitations.accepted.exists?(email: email) &&
          !family.users.where.not(id: id).where.not(onboarded_at: nil).exists?

        assign_attributes(attributes)
        if initial_completion && onboarded_at.present? && set_onboarding_goals_at.present?
          intent = onboarding_ai_mode
        end
        begin
          @applying_onboarding_choice = true
          saved = save
          # The locked, constrained telemetry claim must not revalidate unrelated
          # legacy household preferences or prevent a valid user from onboarding.
          family.update_columns(initial_onboarding_ai_mode: intent) if saved && intent
        ensure
          @applying_onboarding_choice = false
        end
      end
    end

    Usage.capture_onboarding_ai_intent(family_id: family_id, mode: intent) if saved && intent
    saved
  end

  private
    def apply_onboarding_ai_choice
      self.ai_enabled = onboarding_ai_mode == "builtin" if @applying_onboarding_choice
    end

    def normalize_starting_tools
      return if starting_tools.nil? && starting_tool_other.nil?

      self.starting_tools = starting_tools.reject(&:blank?).uniq if starting_tools.is_a?(Array)
      self.starting_tool_other = starting_tool_other.strip.presence if starting_tool_other.is_a?(String)
      self.starting_tool_other = nil unless starting_tools.is_a?(Array) && starting_tools.include?("other")
    end

    def validate_starting_tools
      return if starting_tools.nil?

      unless starting_tools.is_a?(Array) && (starting_tools - STARTING_TOOLS).empty?
        errors.add(:starting_tools, :inclusion)
        return
      end

      errors.add(:starting_tools, :invalid) if starting_tools.include?("nothing_yet") && starting_tools.size > 1
    end
end
