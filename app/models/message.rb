class Message < ApplicationRecord
  belongs_to :chat
  has_many :tool_calls, dependent: :destroy

  enum :status, {
    pending: "pending",
    complete: "complete",
    failed: "failed"
  }

  # A failed reply may be empty when it only carries tool calls that ran.
  validates :content, presence: true, if: :complete?

  after_create_commit -> { broadcast_append_to chat, target: chat.messages_target }, if: :broadcast?
  after_update_commit -> { broadcast_update_to chat }, if: :broadcast?
  # Clears the "Thinking…" bubble if the provider errors before any text streams.
  after_destroy_commit -> { broadcast_remove_to chat }, if: :broadcast?

  scope :ordered, -> { order(created_at: :asc) }

  # The text a provider sees when the conversation is replayed. A failed
  # reply's partial text is left out; the tool calls it ran still count.
  def replayed_content
    failed? ? "" : content.to_s
  end

  private
    def broadcast?
      true
    end
end
