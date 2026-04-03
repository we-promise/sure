class Import::QifCategorySelectionsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    valid_formats         = @import.valid_date_formats_with_preview
    @date_formats         = valid_formats.map { |f| [ f[:label], f[:format] ] }
    @date_previews        = valid_formats.each_with_object({}) { |f, h| h[f[:format]] = f[:preview] }
    @categories           = @import.row_categories
    @tags                 = @import.row_tags
    @category_counts      = @import.rows.group(:category).count.reject { |k, _| k.blank? }
    @tag_counts           = compute_tag_counts
    @split_categories      = @import.split_categories
    @has_split_transactions = @import.has_split_transactions?
  end

  def update
    # If the user changed the date format, re-generate rows with the new format.
    if selection_params[:date_format].present? && selection_params[:date_format] != @import.qif_date_format
      @import.qif_date_format = selection_params[:date_format]
      @import.update_column(:column_mappings, @import.column_mappings)
      @import.generate_rows_from_csv
      @import.sync_mappings
    end

    all_categories = @import.row_categories
    all_tags       = @import.row_tags

    selected_categories = Array(selection_params[:categories]).reject(&:blank?)
    selected_tags       = Array(selection_params[:tags]).reject(&:blank?)

    deselected_categories = all_categories - selected_categories
    deselected_tags       = all_tags - selected_tags

    ActiveRecord::Base.transaction do
      # Clear category on rows whose category was deselected
      if deselected_categories.any?
        @import.rows.where(category: deselected_categories).update_all(category: "")
      end

      # Strip deselected tags from any row that carries them
      if deselected_tags.any?
        @import.rows.where.not(tags: [ nil, "" ]).find_each do |row|
          remaining    = row.tags_list - deselected_tags
          remaining.reject!(&:blank?)
          updated_tags = remaining.join("|")
          row.update_column(:tags, updated_tags) if updated_tags != row.tags.to_s
        end
      end

      @import.sync_mappings
    end

    redirect_to import_clean_path(@import), notice: "Categories and tags saved."
  end

  private

    def set_import
      @import = Current.family.imports.find(params[:import_id])

      unless @import.is_a?(QifImport)
        redirect_to imports_path
      end
    end

    def compute_tag_counts
      counts = Hash.new(0)
      @import.rows.each do |row|
        row.tags_list.each { |tag| counts[tag] += 1 unless tag.blank? }
      end
      counts
    end

    def selection_params
      params.permit(:date_format, categories: [], tags: [])
    end
end
