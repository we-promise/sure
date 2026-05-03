class AssistantMessage < Message
  PROGRESS_STATES = %w[thinking analyzing_data].freeze

  validates :ai_model, presence: true
  validates :progress_state, inclusion: { in: PROGRESS_STATES }, allow_nil: true

  before_validation :clear_progress_state_unless_pending

  def role
    "assistant"
  end

  def progress_state_label
    return I18n.t("chats.thinking") if progress_state.blank?

    I18n.t("chats.#{progress_state}", default: progress_state.humanize)
  end

  def mark_analyzing_data!
    return unless pending?
    return if progress_state == "analyzing_data"

    update!(progress_state: "analyzing_data")
  end

  def append_text!(text)
    self.content += text
    if pending?
      self.status = :complete
      self.progress_state = nil
    end
    save!
  end

  private

    def clear_progress_state_unless_pending
      self.progress_state = nil unless pending?
    end
end
