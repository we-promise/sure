class Import::ConfigurationsController < ApplicationController
  layout "imports"

  SHARED_CONFIGURATION_FIELDS = %w[
    date_col_label amount_col_label name_col_label merchant_col_label category_col_label tags_col_label
    account_col_label qty_col_label ticker_col_label exchange_operating_mic_col_label price_col_label
    entity_type_col_label notes_col_label currency_col_label date_format number_format signage_convention
    amount_type_strategy amount_type_identifier_value amount_type_inflow_value rows_to_skip
  ].freeze

  before_action :set_import

  def show
    # PDF imports are auto-configured from AI extraction, skip to clean step
    redirect_to import_clean_path(@import) and return if @import.is_a?(PdfImport)
    redirect_to import_qif_category_selection_path(@import) and return if @import.is_a?(QifImport)
  end

  def update
    if params[:refresh_only]
      @import.update!(rows_to_skip: params.dig(:import, :rows_to_skip).to_i)
      redirect_to import_configuration_path(@import)
    else
      ActiveRecord::Base.transaction do
        batch_imports = [ @import, *sibling_imports.to_a ]
        @import.update!(import_params)
        @import.generate_rows_from_csv
        batch_imports.drop(1).each do |sibling|
          sibling.update!(shared_configuration)
          sibling.generate_rows_from_csv
        end
        @import.sync_mappings(batch_imports: batch_imports)
      end

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
      params.fetch(:import, {}).permit(
        :date_col_label,
        :amount_col_label,
        :name_col_label,
        :merchant_col_label,
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
        :number_format,
        :signage_convention,
        :amount_type_strategy,
        :amount_type_identifier_value,
        :amount_type_inflow_value,
        :rows_to_skip
      )
    end

    def sibling_imports
      ids = Array(session[:same_format_csv_import_ids]).map(&:to_s)
      return Import.none unless ids.include?(@import.id.to_s)

      Current.family.imports.where(id: ids).where.not(id: @import.id)
    end

    def shared_configuration
      @import.attributes.slice(*SHARED_CONFIGURATION_FIELDS)
    end
end
