class IcostImportsController < ApplicationController
  layout "settings"

  skip_before_action :sync_family

  before_action :require_import_permission!, only: %i[new create publish]
  before_action :set_import, only: %i[show publish]

  def index
    @imports = own_imports.select(:id, :filename, :file_sha256, :created_at, :updated_at).order(created_at: :desc)
  end

  def new
  end

  def create
    file = params.dig(:icost_import, :file)
    unless file.respond_to?(:read) && file.size <= Icost::FileParser::MAX_FILE_BYTES
      redirect_to new_icost_import_path, alert: t("icost_imports.messages.invalid_upload")
      return
    end

    batch = IcostImport.prepare!(family: Current.family, user: Current.user,
                                bytes: file.read, filename: file.original_filename)
    redirect_to icost_import_path(batch), notice: t("icost_imports.messages.prepared")
  rescue Icost::FileParser::Error, IcostImport::Error, ActiveRecord::RecordInvalid
    redirect_to new_icost_import_path, alert: t("icost_imports.messages.invalid_upload")
  end

  def show
    @records = @import.records.order(:source_row)
    @counts = @import.records.group(:status).count
  end

  def publish
    @import.publish!(user: Current.user)
    redirect_to icost_import_path(@import), notice: t("icost_imports.messages.published")
  rescue IcostImport::Error, IcostRecord::ResolutionError, ActiveRecord::RecordInvalid
    redirect_to icost_import_path(@import), alert: t("icost_imports.messages.publish_failed")
  end

  private
    def own_imports
      Current.family.icost_imports.where(user: Current.user)
    end

    def set_import
      @import = own_imports.find(params[:id])
    end

    def require_import_permission!
      head :forbidden if Current.user.guest?
    end
end
