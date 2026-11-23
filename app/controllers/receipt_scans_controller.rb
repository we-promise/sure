class ReceiptScansController < ApplicationController
  include AiFeatureGuard

  before_action :require_preview_features!
  requires_ai :extract_receipt
  before_action :require_receipt_extraction
  before_action :set_accounts

  def new
  end

  def create
    account_id = params.dig(:receipt_scan, :account_id).to_s
    account = @accounts.find { |candidate| candidate.id == account_id }
    return render_new_with_error(t(".account_required")) unless account

    ReceiptScan.create_from_upload!(
      family: Current.family,
      user: Current.user,
      account: account,
      uploads: Array(params.dig(:receipt_scan, :files)).select { |file| file.respond_to?(:read) }
    )

    redirect_to transactions_path, notice: t(".success")
  rescue ReceiptScan::InvalidUpload => e
    render_new_with_error(e.message)
  end

  private
    def require_receipt_extraction
      return if ReceiptScan.extraction_available?(family: Current.family, user: Current.user)

      redirect_back_or_to root_path, alert: t("receipt_scans.unavailable")
    end

    def set_accounts
      @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically.to_a
    end

    def render_new_with_error(message)
      @error = message
      render :new, status: :unprocessable_entity
    end
end
