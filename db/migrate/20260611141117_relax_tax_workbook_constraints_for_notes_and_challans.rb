# frozen_string_literal: true

class RelaxTaxWorkbookConstraintsForNotesAndChallans < ActiveRecord::Migration[7.2]
  GST_OUTWARD_NOTE_AMOUNT_COLUMNS = %i[taxable_value igst cgst sgst_ugst cess].freeze
  TDS_TOTAL_AMOUNT_COMPONENT_SUM = "tax + interest + fee + penalty + others"

  def up
    GST_OUTWARD_NOTE_AMOUNT_COLUMNS.each do |column|
      remove_check_constraint :gst_outward_lines, name: "chk_gst_outward_lines_#{column}_non_negative"
      add_check_constraint :gst_outward_lines,
                           "#{column} IS NULL OR #{column} >= 0 OR is_credit_note OR is_debit_note",
                           name: "chk_gst_outward_lines_#{column}_non_negative"
    end

    add_check_constraint :tds_challans,
                         "total_amount = #{TDS_TOTAL_AMOUNT_COMPONENT_SUM}",
                         name: "chk_tds_challans_total_amount_matches_components"
  end

  def down
    remove_check_constraint :tds_challans, name: "chk_tds_challans_total_amount_matches_components"

    GST_OUTWARD_NOTE_AMOUNT_COLUMNS.each do |column|
      remove_check_constraint :gst_outward_lines, name: "chk_gst_outward_lines_#{column}_non_negative"
      add_check_constraint :gst_outward_lines,
                           "#{column} IS NULL OR #{column} >= 0",
                           name: "chk_gst_outward_lines_#{column}_non_negative"
    end
  end
end
