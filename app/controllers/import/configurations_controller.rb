class Import::ConfigurationsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    # PDF imports are auto-configured from AI extraction, skip to clean step
    redirect_to import_clean_path(@import) and return if @import.is_a?(PdfImport)
    redirect_to import_qif_category_selection_path(@import) and return if @import.is_a?(QifImport)
  end

  def update
    @import.transaction do
      @import.update!(import_params)
      if @import.saved_changes.except("updated_at").any?
        @import.rows.destroy_all
        @import.update_column(:rows_count, 0)
        @import.mappings.destroy_all
      end
    end

    if params[:refresh_only]
      redirect_to import_configuration_path(@import)
    else
      @import.generate_rows_from_csv
      @import.reload.sync_mappings
      redirect_to import_clean_path(@import), notice: t(".success")
    end
  rescue ActiveRecord::RecordInvalid => e
    message = e.record.errors.full_messages.to_sentence.presence || e.message
    redirect_back_or_to import_configuration_path(@import), alert: message
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def import_params
      timestamp_keys = @import.is_a?(TransactionImport) ? %i[date_basis date_timezone] : []
      params.fetch(:import, {}).permit(
        :date_col_label,
        :amount_col_label,
        :name_col_label,
        :category_col_label,
        :tags_col_label,
        :account_col_label,
        :qty_col_label,
        :ticker_col_label,
        :exchange_operating_mic_col_label,
        :price_col_label,
        :entity_type_col_label,
        :notes_col_label,
        :currency_col_label,
        :date_format,
        :timestamp_col_label,
        :number_format,
        :signage_convention,
        :amount_type_strategy,
        :amount_type_identifier_value,
        :amount_type_inflow_value,
        :rows_to_skip,
        *timestamp_keys
      )
    end
end
