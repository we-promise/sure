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
      format.html { redirect_to family_exports_path, notice: t("family_exports.create.success") }
      format.turbo_stream {
        stream_redirect_to family_exports_path, notice: t("family_exports.create.success")
      }
    end
  end

  def index
    @pagy, @exports = pagy(Current.family.family_exports.ordered, limit: safe_per_page)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.exports"), family_exports_path ]
    ]

    respond_to do |format|
      format.html { render layout: "settings" }
      format.turbo_stream { redirect_to family_exports_path }
    end
  end

  def download
    if @export.downloadable?
      redirect_to @export.export_file, allow_other_host: true
    else
      redirect_to family_exports_path, alert: t("family_exports.export_not_ready")
    end
  end

  def destroy
    @export.destroy
    redirect_to family_exports_path, notice: t("family_exports.destroy.success")
  end

  private

    def set_export
      @export = Current.family.family_exports.find(params[:id])
    end

    def require_admin
      unless Current.user.admin?
        redirect_to root_path, alert: t("family_exports.access_denied")
      end
    end
end
