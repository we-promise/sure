class FamilyExportsController < ApplicationController
  include StreamExtensions

  before_action :require_admin
  before_action :set_export, only: [ :download, :destroy ]

  def new
    # Modal view for initiating export
  end

  def create
    @export = Current.family.family_exports.create!
    FamilyDataExportJob.perform_later(@export)

    respond_to do |format|
      format.html { redirect_to family_exports_path, notice: "Export started. You'll be able to download it shortly." }
      format.turbo_stream {
        stream_redirect_to family_exports_path, notice: "Export started. You'll be able to download it shortly."
      }
    end
  end

  def index
    @pagy, @exports = pagy(Current.family.family_exports.ordered, limit: params[:per_page] || 10)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.exports"), family_exports_path ]
    ]
    render layout: "settings"
  end

  def download
    if @export.downloadable?
      redirect_to @export.export_file, allow_other_host: true
    else
      redirect_to family_exports_path, alert: "Export not ready for download"
    end
  end

  def destroy
    @export.destroy
    redirect_to family_exports_path, notice: "Export deleted successfully"
  end

  private

    def set_export
      @export = Current.family.family_exports.find(params[:id])
    end

    def require_admin
      unless Current.user.admin?
        redirect_to root_path, alert: "Access denied"
      end
    end
end
