# Receives raw alert emails relayed by a mail worker (see
# docs/providers/email-alerts.md). The secret token in the URL selects the
# connection; authenticity of each alert is established later from the bank's
# DKIM signature, not from the caller.
#
# 202: stored for processing. 200: not from a supported institution, so the
# relay can forward it elsewhere (for example Gmail's forwarding confirmation).
class Webhooks::EmailAlertsController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_authentication

  def create
    item = EmailAlertItem.active.find_by(inbound_token: params[:token].to_s)
    return head :not_found unless item

    raw = request.body.read(EmailAlert::MimeMessage::MAX_BYTES + 1).to_s
    return head :content_too_large if raw.bytesize > EmailAlert::MimeMessage::MAX_BYTES
    return head :bad_request if raw.blank?

    mime = EmailAlert::MimeMessage.new(raw)
    unless EmailAlert::Parsers.for_domain(mime.from_domain)
      return render json: { status: "ignored" }, status: :ok
    end

    message = EmailAlertMessage.receive!(item, raw)
    EmailAlertMessageJob.perform_later(message) if message.pending?

    render json: { status: "accepted" }, status: :accepted
  end
end
