# Stops an AI reading that is still running. The import itself, and anything it already committed,
# stays; a request the model already sent may still finish, but its answer is fenced out.
class PdfImports::AiProcessingsController < ApplicationController
  before_action :set_import
  before_action :require_statement_import_permission!

  def destroy
    if @import.cancel_ai_processing!
      redirect_to import_path(@import), notice: t(".stopped")
    else
      redirect_to import_path(@import), alert: t(".not_processing")
    end
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:pdf_import_id])
      raise ActiveRecord::RecordNotFound unless @import.is_a?(PdfImport) && @import.viewable_by?(Current.user)
    end

    def require_statement_import_permission!
      statement = @import.account_statement
      return if statement.blank? || statement.manageable_by?(Current.user)

      redirect_back_or_to @import.account || statement, alert: t("accounts.not_authorized")
    end
end
