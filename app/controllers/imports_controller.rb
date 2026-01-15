class ImportsController < ApplicationController
  include SettingsHelper

  before_action :set_import, only: %i[show publish destroy revert apply_template]

  def publish
    @import.publish_later

    redirect_to import_path(@import), notice: t(".started")
  rescue Import::MaxRowCountExceededError
    redirect_back_or_to import_path(@import), alert: t(".max_row_count_exceeded", count: @import.max_row_count)
  end

  def index
    @imports = Current.family.imports
    @exports = Current.user.admin? ? Current.family.family_exports.ordered.limit(10) : nil
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Import/Export", imports_path ]
    ]
    render layout: "settings"
  end

  def new
    @pending_import = Current.family.imports.ordered.pending.first
  end

  def create
    type = params.dig(:import, :type).to_s
    type = "TransactionImport" unless Import::TYPES.include?(type)

    account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))
    import = Current.family.imports.create!(
      type: type,
      account: account,
      date_format: Current.family.date_format,
    )

    if import_params[:csv_file].present?
      file = import_params[:csv_file]

      if file.size > Import::MAX_CSV_SIZE
        import.destroy
        redirect_to new_import_path, alert: t(".file_too_large", size: Import::MAX_CSV_SIZE / 1.megabyte)
        return
      end

      unless Import::ALLOWED_MIME_TYPES.include?(file.content_type)
        import.destroy
        redirect_to new_import_path, alert: t(".invalid_file_type")
        return
      end

      # Stream reading is not fully applicable here as we store the raw string in the DB,
      # but we have validated size beforehand to prevent memory exhaustion from massive files.
      import.update!(raw_file_str: file.read)
      redirect_to import_configuration_path(import), notice: t(".csv_uploaded")
    else
      redirect_to import_upload_path(import)
    end
  end

  def show
    if !@import.uploaded?
      redirect_to import_upload_path(@import), alert: t(".finalize_upload")
    elsif !@import.publishable?
      redirect_to import_confirm_path(@import), alert: t(".finalize_mappings")
    end
  end

  def revert
    @import.revert_later
    redirect_to imports_path, notice: t(".reverting")
  end

  def apply_template
    if @import.suggested_template
      @import.apply_template!(@import.suggested_template)
      redirect_to import_configuration_path(@import), notice: t(".template_applied")
    else
      redirect_to import_configuration_path(@import), alert: t(".no_template")
    end
  end

  def destroy
    @import.destroy

    redirect_to imports_path, notice: t(".deleted")
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:id])
    end

    def import_params
      params.require(:import).permit(:csv_file)
    end
end
