json.data do
  json.id @import.id
  json.type @import.type
  json.status @import.status
  json.created_at @import.created_at
  json.updated_at @import.updated_at
  json.account_id @import.account_id
  json.error @import.error if @import.error.present?

  json.configuration do
    json.date_col_label @import.date_col_label
    json.amount_col_label @import.amount_col_label
    json.name_col_label @import.name_col_label
    json.category_col_label @import.category_col_label
    json.tags_col_label @import.tags_col_label
    json.notes_col_label @import.notes_col_label
    json.account_col_label @import.account_col_label
    json.date_format @import.date_format
    json.number_format @import.number_format
    json.signage_convention @import.signage_convention
  end

  json.stats do
    json.rows_count @import.rows_count
    json.valid_rows_count @import.rows.select(&:valid?).count if @import.rows.loaded?
  end

  # Only show a subset of rows for preview if needed, or link to a separate rows endpoint
  # json.sample_rows @import.rows.limit(5)
end
