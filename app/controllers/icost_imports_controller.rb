class IcostImportsController < ApplicationController
  layout "settings"

  skip_before_action :sync_family

  before_action :require_import_permission!, only: %i[new create publish resolve_accounts]
  before_action :set_import, only: %i[show publish resolve_accounts]

  def index
    @imports = own_imports.select(:id, :filename, :file_sha256, :created_at, :updated_at).order(created_at: :desc)
    @counts = IcostRecord.where(icost_import_id: @imports.reselect(:id)).group(:icost_import_id, :status).count
    @publishing = @imports.any?(&:publishing?)
  end

  def new
  end

  def create
    files = Array(params.dig(:icost_import, :files) || params.dig(:icost_import, :file)).reject(&:blank?)
    unless files.any? && files.size <= IcostImport::MAX_FILES && files.all? { |file| file.respond_to?(:original_filename) }
      redirect_to new_icost_import_path, alert: t("icost_imports.messages.invalid_upload")
      return
    end

    batches = []
    errors = []
    files.each do |file|
      begin
        raise Icost::FileParser::Error, "file_too_large" unless file.respond_to?(:read) && file.size <= Icost::FileParser::MAX_FILE_BYTES
        batches << IcostImport.prepare!(family: Current.family, user: Current.user,
          bytes: file.read, filename: file.original_filename)
        batches.last.publish_later(user: Current.user) if params.dig(:icost_import, :auto_post) == "1"
      rescue Icost::FileParser::Error => error
        errors << { "filename" => File.basename(file.original_filename).truncate_bytes(60), "code" => error.code }
        DebugLogEntry.capture(category: "import", level: "warn", message: "iCost upload rejected",
          source: self.class.name, provider_key: "icost", family: Current.family,
          metadata: { error_code: error.code })
      rescue IcostImport::Error, ActiveRecord::RecordInvalid => error
        errors << { "filename" => File.basename(file.original_filename).truncate_bytes(60), "code" => "invalid_source" }
        DebugLogEntry.capture(category: "import", level: "warn", message: "iCost upload could not be staged",
          source: self.class.name, provider_key: "icost", family: Current.family,
          metadata: { error_class: error.class.name })
      end
    end
    flash[:icost_upload_errors] = errors if errors.any?
    flash[:alert] = helpers.icost_upload_error(errors.first) if errors.any?
    flash[:notice] = t("icost_imports.messages.prepared") if batches.any?
    destination = if batches.empty?
      new_icost_import_path
    elsif files.one?
      icost_import_path(batches.first)
    else
      icost_imports_path
    end
    redirect_to destination, status: :see_other
  end

  def show
    @records = @import.records.order(:source_row)
    @counts = @import.records.group(:status).count
    @account_groups = @import.account_groups
    @accounts = Current.family.accounts.writable_by(Current.user).visible.manual.order(:name)
    @publishing = @import.publishing?
  end

  def resolve_accounts
    mappings = params.require(:account_mappings).permit(mappings: [ :source_account, :currency, :account_id ])
    @import.resolve_accounts!(user: Current.user, mappings: mappings.fetch(:mappings, {}).values)
    redirect_to icost_import_path(@import), notice: t("icost_imports.messages.review_saved"), status: :see_other
  rescue IcostImport::Error, IcostRecord::ResolutionError, ActiveRecord::RecordInvalid
    redirect_to icost_import_path(@import), alert: t("icost_imports.messages.review_invalid"), status: :see_other
  end

  def publish
    @import.publish_later(user: Current.user)
    redirect_to icost_import_path(@import), notice: t("icost_imports.queued"), status: :see_other
  rescue IcostImport::Error, IcostRecord::ResolutionError, ActiveRecord::RecordInvalid
    redirect_to icost_import_path(@import), alert: t("icost_imports.messages.publish_failed")
  end

  private
    def default_breadcrumbs
      [ [ I18n.t("breadcrumbs.home"), root_path ], [ I18n.t("icost_imports.title"), nil ] ]
    end

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
