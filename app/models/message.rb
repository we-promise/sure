class Message < ApplicationRecord
  belongs_to :chat
  has_many :tool_calls, dependent: :destroy

  enum :status, {
    pending: "pending",
    complete: "complete",
    failed: "failed"
  }

  validates :content, presence: true, unless: :pending?

  after_create_commit -> { broadcast_append_to chat, target: chat.messages_target }, if: :broadcast?
  after_update_commit -> { broadcast_update_to chat }, if: :broadcast?
  # Without this, a destroyed message leaves its rendered bubble on the page.
  # The assistant demotes/destroys the streamed-nothing message when a provider
  # call fails before any text arrives (see `Assistant::Builtin#respond_to`), so
  # the pending "Thinking…" bubble would otherwise hang there forever.
  after_destroy_commit -> { broadcast_remove_to chat }, if: :broadcast?

  scope :ordered, -> { order(created_at: :asc) }

  private
    def broadcast?
      true
    end
end
