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
    return false if pending? && !claim!

    self.content += text
    save!
  end

  private

    # Flips pending -> complete with a conditional UPDATE, so the check and the
    # state change cannot be separated by the watchdog's write. Returns false if
    # the row is already gone or `failed`, meaning this turn lost the race and
    # must not write. A plain read-then-save would leave a window in which the
    # watchdog demotes the row between the two, and the late content would land
    # on a bubble the user was already told had failed.
    #
    # Only reached on the first append (later ones are no longer `pending`), so
    # a streaming response pays for this once, not once per chunk.
    def claim!
      return true unless persisted?

      claimed = self.class.where(id: id, status: :pending).update_all(status: "complete").positive?
      self.status = :complete if claimed
      claimed
    end
end
