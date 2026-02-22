class Import::ConfigurationsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    # PDF imports are auto-configured from AI extraction, skip to clean step
    redirect_to import_clean_path(@import) if @import.type == "PdfImport"
  end

  def update
    if params[:refresh_only]
      @import.update!(rows_to_skip: params.dig(:import, :rows_to_skip).to_i)
      redirect_to import_configuration_path(@import)
    else
      handle_positions_file if @import.type == "FidelityImport"

      @import.update!(import_params)
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

    def handle_positions_file
      positions_file = params.dig(:import, :positions_file)
      return unless positions_file.present?

      @import.positions_file_str = positions_file.read

      # Store selected account number if provided
      acct_num = params.dig(:import, :positions_account_number)
      @import.positions_account_number = acct_num if acct_num.present?
    end

    def import_params
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
        :category_parent_col_label,
        :paid_by_col_label,
        :date_format,
        :number_format,
        :signage_convention,
        :amount_type_strategy,
        :amount_type_identifier_value,
        :amount_type_inflow_value,
        :rows_to_skip
      )
    end
end
