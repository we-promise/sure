# A raw alert email received for an EmailAlertItem.
#
# Messages are stored before they are processed so a parser fix or a newly
# linked account can be applied to mail that already arrived. +process!+ moves a
# message to one terminal state:
#   processed       transaction imported into the linked Sure account
#   awaiting_link   parsed, but its provider account is not linked yet
#   ignored         from the institution but not a transaction (OTP, notice)
#   rejected        sender not supported or DKIM did not verify
#   failed          unexpected error, or DKIM key lookup failed; retried on sync
class EmailAlertMessage < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :raw_base64
    encrypts :parsed_payload
  end

  enum :status, {
    pending: "pending",
    processed: "processed",
    awaiting_link: "awaiting_link",
    ignored: "ignored",
    rejected: "rejected",
    failed: "failed"
  }, default: :pending

  belongs_to :email_alert_item
  belongs_to :email_alert_account, optional: true

  validates :raw_base64, :fingerprint, presence: true

  scope :retryable, -> { where(status: [ :pending, :awaiting_link, :failed ]) }
  scope :recent_first, -> { order(received_at: :desc) }

  # Stores an inbound message once; a redelivered message returns the existing row.
  def self.receive!(item, raw)
    mime = EmailAlert::MimeMessage.new(raw)
    fingerprint = Digest::SHA256.hexdigest(mime.message_id.presence || raw.to_s.b)

    item.email_alert_messages.create_with(
      raw_base64: Base64.strict_encode64(raw.to_s.b),
      from_address: mime.from_address,
      subject: mime.subject.truncate(255),
      received_at: Time.current
    ).find_or_create_by!(fingerprint: fingerprint)
  rescue ActiveRecord::RecordNotUnique
    item.email_alert_messages.find_by!(fingerprint: fingerprint)
  end

  # Kept as base64 because DKIM verifies over the exact original bytes, which
  # need not be valid UTF-8.
  def raw
    Base64.strict_decode64(raw_base64)
  end

  def mime
    @mime ||= EmailAlert::MimeMessage.new(raw)
  end

  def parsed_alert
    return nil if parsed_payload.blank?

    data = JSON.parse(parsed_payload).symbolize_keys
    EmailAlert::ParsedAlert.new(
      **data.merge(
        amount: BigDecimal(data[:amount]),
        balance: data[:balance] && BigDecimal(data[:balance]),
        direction: data[:direction].to_sym,
        category_hint: data[:category_hint]&.to_sym,
        occurred_at: data[:occurred_at] && Time.iso8601(data[:occurred_at]),
        details: data[:details] || {}
      )
    )
  end

  def process!
    EmailAlertMessage::Processor.new(self).process
  end
end
