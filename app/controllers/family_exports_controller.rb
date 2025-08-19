class FamilyExportsController < ApplicationController
  include StreamExtensions

  before_action :require_admin
  before_action :set_export, only: [ :download ]

  def new
    # Modal view for initiating export
  end

  def create
    @export = Current.family.family_exports.create!
    FamilyDataExportJob.perform_later(@export)

    respond_to do |format|
      format.html { redirect_to imports_path, notice: "Export started. You'll be able to download it shortly." }
      format.turbo_stream {
        stream_redirect_to imports_path, notice: "Export started. You'll be able to download it shortly."
      }
    end
  end

  def index
    @exports = Current.family.family_exports.ordered.limit(10)
    render layout: false # For turbo frame
  end

  def download
    if @export.downloadable?
      redirect_to @export.export_file, allow_other_host: true
    else
      redirect_to imports_path, alert: "Export not ready for download"
    end
  end

  def destroy
    @export = Current.family.family_exports.find(params[:id])

    if @export.destroy
      # Queue background job to clean up files
      FamilyExportCleanupJob.perform_later(@export.id, @export.filename) if @export.export_file.attached?

      respond_to do |format|
        format.html { redirect_to imports_path, notice: "Export has been deleted successfully." }
        format.turbo_stream {
          stream_redirect_to imports_path, notice: "Export has been deleted successfully."
        }
      end
    else
      redirect_to imports_path, alert: "Failed to delete export."
    end
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
