# frozen_string_literal: true

# Serves a transaction's attachment (a receipt photo, an invoice PDF) to API clients. Active
# Storage's own URLs authenticate by browser session, which the mobile app doesn't have.
class Api::V1::TransactionAttachmentsController < Api::V1::BaseController
  include Api::V1::TransactionLookup

  before_action :ensure_read_scope
  before_action -> { load_accessible_transaction(params[:transaction_id]) }

  def show
    attachment = @transaction.attachments.find_by(id: params[:id]) if valid_uuid?(params[:id])
    return render_json({ error: "not_found", message: "Attachment not found" }, status: :not_found) unless attachment

    if params[:variant] == "thumbnail" && attachment.variable?
      variant = attachment.variant(:thumbnail).processed
      send_data variant.download, type: variant.content_type || attachment.content_type, disposition: "inline"
    else
      send_data attachment.download, type: attachment.content_type, disposition: "inline", filename: attachment.filename.to_s
    end
  end
end
