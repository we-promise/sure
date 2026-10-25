class IcostRecordsController < ApplicationController
  layout "settings"

  skip_before_action :sync_family

  before_action :set_record

  def show
    @accounts = Current.family.accounts.writable_by(Current.user).manual.visible.where(currency: @record.currency).order(:name)
    @duplicate_record = IcostRecord.owned_by(Current.user).find_by(id: @record.resolution["duplicate_of_id"]) if @record.resolution["duplicate_of_id"].present?
  end

  def update
    return head :forbidden if Current.user.guest?

    @record.resolve!(user: Current.user, attributes: resolution_params.to_h)
    redirect_to icost_import_record_path(@import, @record), notice: t("icost_imports.messages.review_saved")
  rescue IcostRecord::ResolutionError, ActiveRecord::RecordInvalid
    redirect_to icost_import_record_path(@import, @record), alert: t("icost_imports.messages.review_invalid")
  end

  private
    def default_breadcrumbs
      [
        [ I18n.t("breadcrumbs.home"), root_path ],
        [ I18n.t("icost_imports.title"), icost_imports_path ],
        [ I18n.t("icost_imports.record_title", row: @record.source_row), nil ]
      ]
    end

    def set_record
      @import = Current.family.icost_imports.where(user: Current.user).find(params[:icost_import_id])
      @record = @import.records.find(params[:id])
    end

    def resolution_params
      params.require(:resolution).permit(:account_id, :from_account_id, :to_account_id, :review_note)
    end
end
