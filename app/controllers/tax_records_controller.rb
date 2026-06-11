class TaxRecordsController < ApplicationController
  before_action :require_admin

  def index
    @q = params.fetch(:q, ActionController::Parameters.new).permit(:search)
    @gst_taxable_total = Current.family.gst_outward_lines.sum(:taxable_value)
    @tds_total = Current.family.tds_deductions.sum(:tds_amount)
    @pagy, @gst_outward_lines = pagy(filtered_gst_outward_lines, limit: safe_per_page)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.tax_records"), tax_records_path ]
    ]

    render layout: "settings"
  end

  private
    def filtered_gst_outward_lines
      scope = Current.family.gst_outward_lines
        .includes(:tax_workbook_import)
        .order(invoice_date: :desc, invoice_no: :desc)

      return scope if @q[:search].blank?

      query = "%#{ActiveRecord::Base.sanitize_sql_like(@q[:search].strip)}%"
      scope.where(
        "invoice_no ILIKE :query OR gstin ILIKE :query OR recipient_gstin_or_uin ILIKE :query",
        query: query
      )
    end

    def require_admin
      return if Current.user&.admin?

      redirect_to root_path, alert: t("accounts.not_authorized")
    end
end
