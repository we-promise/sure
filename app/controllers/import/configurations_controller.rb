class Import::ConfigurationsController < ApplicationController
  include ImportGuestGuardable

  layout "imports"

  before_action :set_import
  before_action :require_import_editable!, only: :update

  def show
    # PDF imports are auto-configured from AI extraction, skip to clean step
    redirect_to import_clean_path(@import) and return if @import.is_a?(PdfImport)
    redirect_to import_qif_category_selection_path(@import) and return if @import.is_a?(QifImport)
    return unless @import.is_a?(MonarchImport)

    redirect_to import_upload_path(@import) and return unless @import.uploaded?

    @target_accounts = monarch_target_accounts
    render :monarch
  end

  def update
    if @import.is_a?(MonarchImport)
      @import.apply_account_choices!(monarch_choices, target_accounts: monarch_target_accounts)
      redirect_to import_path(@import), notice: t(".monarch_success")
    elsif params[:refresh_only]
      @import.update!(rows_to_skip: params.dig(:import, :rows_to_skip).to_i)
      redirect_to import_configuration_path(@import)
    else
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

    # Existing accounts a Monarch account can go into: the manual ones this
    # user can access.
    def monarch_target_accounts
      Import::MonarchAccountMapping.target_accounts_for(@import).where(id: accessible_accounts.select(:id))
    end

    MONARCH_CHOICE_FIELDS = %i[name type target_id closed include transactions current_balance].freeze

    def monarch_choices
      accounts = params.fetch(:accounts, {})
      accounts.permit(accounts.keys.index_with { MONARCH_CHOICE_FIELDS }).to_h.transform_values(&:symbolize_keys)
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
