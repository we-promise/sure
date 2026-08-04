class AssistantMessage < Message
  validates :ai_model, presence: true

  def role
    "assistant"
  end

  # Appends streamed (or, for non-streaming providers, whole) response text.
  #
  # Returns false without saving if the bubble is no longer awaiting a response.
  # The watchdog runs in the *web* process and may have destroyed or failed this
  # message while the job was still waiting on a slow model; the job holds its
  # own in-memory copy and would otherwise silently resurrect a bubble the user
  # has already been told failed. Re-checked once, on the first append — later
  # appends stay in-memory cheap.
  def append_text!(text)
    return false if destroyed? || frozen?

    if pending?
      return false if persisted? && !self.class.where(id: id, status: :pending).exists?

      self.status = :complete
    end

    self.content += text
    save!
  end
end
