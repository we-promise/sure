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
  # Clears the "Thinking…" bubble if the provider errors before any text streams.
  after_destroy_commit -> { broadcast_remove_to chat }, if: :broadcast?

  scope :ordered, -> { order(created_at: :asc) }

  # Tool calls grouped by the round that produced them, in call order. Rows
  # saved before rounds were recorded have no round and form a single group.
  def tool_call_rounds
    ordered = tool_calls.each_with_index.sort_by do |tool_call, index|
      [ tool_call.round.to_i, tool_call.created_at || Time.zone.at(0), tool_call.id.to_s, index ]
    end.map(&:first)

    Assistant::Responder.group_by_round(ordered)
  end

  private
    def broadcast?
      true
    end
end
