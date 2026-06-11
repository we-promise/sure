# frozen_string_literal: true

class CreateTaxWorkbookImports < ActiveRecord::Migration[7.2]
  MAX_WORKBOOK_BYTES = 10.megabytes

  def change
    create_table :tax_workbook_imports, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :uploaded_by, foreign_key: { to_table: :users, on_delete: :nullify }, type: :uuid

      t.string :status, null: false, default: "pending"
      t.string :filename, null: false, limit: 255
      t.string :content_type, null: false, limit: 100
      t.bigint :byte_size, null: false
      t.string :checksum, null: false, limit: 64
      t.string :template_version, null: false, limit: 100
      t.string :entity_name
      t.string :gstin, limit: 15
      t.string :tan, limit: 10
      t.string :fy
      t.date :tax_period_month
      t.string :tax_period_quarter
      t.jsonb :row_counts, null: false, default: {}
      t.jsonb :validation_errors, null: false, default: []
      t.jsonb :metadata, null: false, default: {}

      t.timestamps

      t.index [ :family_id, :tax_period_month ]
      t.index [ :family_id, :tax_period_quarter ]
      t.index [ :family_id, :checksum ], unique: true
      t.index [ :id, :family_id ], unique: true
    end

    add_check_constraint :tax_workbook_imports,
                         "status IN ('pending', 'validated', 'importing', 'complete', 'failed')",
                         name: "chk_tax_workbook_imports_status"
    add_check_constraint :tax_workbook_imports,
                         "byte_size > 0",
                         name: "chk_tax_workbook_imports_byte_size_positive"
    add_check_constraint :tax_workbook_imports,
                         "byte_size <= #{MAX_WORKBOOK_BYTES}",
                         name: "chk_tax_workbook_imports_byte_size_max"
    add_check_constraint :tax_workbook_imports,
                         "content_type = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'",
                         name: "chk_tax_workbook_imports_content_type"
    add_check_constraint :tax_workbook_imports,
                         "char_length(checksum) = 64",
                         name: "chk_tax_workbook_imports_checksum_length"
    add_check_constraint :tax_workbook_imports,
                         "jsonb_typeof(row_counts) = 'object'",
                         name: "chk_tax_workbook_imports_row_counts_object"
    add_check_constraint :tax_workbook_imports,
                         "jsonb_typeof(validation_errors) = 'array'",
                         name: "chk_tax_workbook_imports_validation_errors_array"
    add_check_constraint :tax_workbook_imports,
                         "jsonb_typeof(metadata) = 'object'",
                         name: "chk_tax_workbook_imports_metadata_object"

    create_table :gst_outward_lines, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :tax_workbook_import, null: false, foreign_key: { on_delete: :cascade }, type: :uuid

      t.integer :source_row_number, null: false
      t.date :tax_period_month, null: false
      t.string :gstin, limit: 15, null: false
      t.string :gstr1_table_code, null: false
      t.string :invoice_no, null: false
      t.date :invoice_date, null: false
      t.string :recipient_gstin_or_uin, limit: 15
      t.string :place_of_supply_state
      t.string :hsn_code
      t.decimal :rate_pct, precision: 8, scale: 4
      t.decimal :taxable_value, precision: 19, scale: 4, null: false, default: 0
      t.decimal :igst, precision: 19, scale: 4, null: false, default: 0
      t.decimal :cgst, precision: 19, scale: 4, null: false, default: 0
      t.decimal :sgst_ugst, precision: 19, scale: 4, null: false, default: 0
      t.decimal :cess, precision: 19, scale: 4, null: false, default: 0
      t.boolean :is_reverse_charge, null: false, default: false
      t.boolean :is_export, null: false, default: false
      t.boolean :is_ecommerce_tcs, null: false, default: false
      t.boolean :is_credit_note, null: false, default: false
      t.boolean :is_debit_note, null: false, default: false

      t.timestamps
    end

    add_index :gst_outward_lines, [ :family_id, :tax_period_month ]
    add_index :gst_outward_lines, [ :family_id, :gstin ]
    add_index :gst_outward_lines, [ :family_id, :invoice_no ]
    add_import_family_foreign_key :gst_outward_lines
    add_positive_row_constraint :gst_outward_lines
    add_non_negative_constraints :gst_outward_lines, %i[rate_pct taxable_value igst cgst sgst_ugst cess]

    create_table :gst3b_summaries, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :tax_workbook_import, null: false, foreign_key: { on_delete: :cascade }, type: :uuid

      t.integer :source_row_number, null: false
      t.date :tax_period_month, null: false
      t.string :gstin, limit: 15, null: false
      t.string :section_code, null: false
      t.decimal :taxable_value, precision: 19, scale: 4, null: false, default: 0
      t.decimal :igst, precision: 19, scale: 4, null: false, default: 0
      t.decimal :cgst, precision: 19, scale: 4, null: false, default: 0
      t.decimal :sgst_ugst, precision: 19, scale: 4, null: false, default: 0
      t.decimal :cess, precision: 19, scale: 4, null: false, default: 0
      t.decimal :interest, precision: 19, scale: 4, null: false, default: 0
      t.decimal :late_fee, precision: 19, scale: 4, null: false, default: 0

      t.timestamps
    end

    add_index :gst3b_summaries, [ :family_id, :tax_period_month ]
    add_import_family_foreign_key :gst3b_summaries
    add_positive_row_constraint :gst3b_summaries
    add_non_negative_constraints :gst3b_summaries, %i[taxable_value igst cgst sgst_ugst cess interest late_fee]

    create_table :gst_hsn_summaries, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :tax_workbook_import, null: false, foreign_key: { on_delete: :cascade }, type: :uuid

      t.integer :source_row_number, null: false
      t.date :tax_period_month, null: false
      t.string :gstin, limit: 15, null: false
      t.string :hsn_code, null: false
      t.string :description
      t.string :uqc
      t.decimal :quantity, precision: 19, scale: 4, null: false, default: 0
      t.decimal :taxable_value, precision: 19, scale: 4, null: false, default: 0
      t.decimal :igst, precision: 19, scale: 4, null: false, default: 0
      t.decimal :cgst, precision: 19, scale: 4, null: false, default: 0
      t.decimal :sgst_ugst, precision: 19, scale: 4, null: false, default: 0
      t.decimal :cess, precision: 19, scale: 4, null: false, default: 0
      t.string :bucket, null: false

      t.timestamps
    end

    add_index :gst_hsn_summaries, [ :family_id, :tax_period_month ]
    add_index :gst_hsn_summaries, [ :family_id, :hsn_code ]
    add_import_family_foreign_key :gst_hsn_summaries
    add_positive_row_constraint :gst_hsn_summaries
    add_non_negative_constraints :gst_hsn_summaries, %i[quantity taxable_value igst cgst sgst_ugst cess]

    create_table :tds_challans, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :tax_workbook_import, null: false, foreign_key: { on_delete: :cascade }, type: :uuid

      t.integer :source_row_number, null: false
      t.string :tax_period_quarter, null: false
      t.string :tan, limit: 10, null: false
      t.string :challan_ref, null: false
      t.string :mode_of_deposit
      t.string :bsr_code_or_receipt_no
      t.string :challan_serial_no_or_ddo_serial_no
      t.date :deposit_date
      t.string :minor_head
      t.decimal :tax, precision: 19, scale: 4, null: false, default: 0
      t.decimal :interest, precision: 19, scale: 4, null: false, default: 0
      t.decimal :fee, precision: 19, scale: 4, null: false, default: 0
      t.decimal :penalty, precision: 19, scale: 4, null: false, default: 0
      t.decimal :others, precision: 19, scale: 4, null: false, default: 0
      t.decimal :total_amount, precision: 19, scale: 4, null: false, default: 0

      t.timestamps
    end

    add_index :tds_challans, [ :family_id, :tax_period_quarter ]
    add_index :tds_challans, [ :family_id, :challan_ref ]
    add_index :tds_challans, [ :id, :family_id, :tax_workbook_import_id ], unique: true, name: "index_tds_challans_on_id_family_import"
    add_index :tds_challans, [ :tax_workbook_import_id, :family_id, :challan_ref ], unique: true, name: "index_tds_challans_on_import_family_ref"
    add_import_family_foreign_key :tds_challans
    add_positive_row_constraint :tds_challans
    add_check_constraint :tds_challans,
                         "btrim(challan_ref) <> ''",
                         name: "chk_tds_challans_challan_ref_present"
    add_non_negative_constraints :tds_challans, %i[tax interest fee penalty others total_amount]

    create_table :tds_deductions, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :tax_workbook_import, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :tds_challan, foreign_key: { on_delete: :nullify }, type: :uuid

      t.integer :source_row_number, null: false
      t.date :tax_period_month, null: false
      t.string :tax_period_quarter, null: false
      t.string :deductor_tan, limit: 10, null: false
      t.string :deductee_pan_or_aadhaar, null: false
      t.string :deductee_name
      t.string :section_code, null: false
      t.date :booking_date
      t.date :payment_date
      t.decimal :amount_paid, precision: 19, scale: 4, null: false, default: 0
      t.decimal :tds_rate_pct, precision: 8, scale: 4
      t.decimal :tds_amount, precision: 19, scale: 4, null: false, default: 0
      t.decimal :surcharge, precision: 19, scale: 4, null: false, default: 0
      t.decimal :cess, precision: 19, scale: 4, null: false, default: 0
      t.string :challan_ref
      t.string :resident_status

      t.timestamps
    end

    add_index :tds_deductions, [ :family_id, :tax_period_month ]
    add_index :tds_deductions, [ :family_id, :tax_period_quarter ]
    add_index :tds_deductions, [ :family_id, :deductee_pan_or_aadhaar ]
    add_index :tds_deductions, [ :family_id, :section_code ]
    add_import_family_foreign_key :tds_deductions
    add_foreign_key :tds_deductions,
                    :tds_challans,
                    column: [ :tds_challan_id, :family_id, :tax_workbook_import_id ],
                    primary_key: [ :id, :family_id, :tax_workbook_import_id ],
                    name: "fk_tds_deductions_challan_family_import"
    add_foreign_key :tds_deductions,
                    :tds_challans,
                    column: [ :tax_workbook_import_id, :family_id, :challan_ref ],
                    primary_key: [ :tax_workbook_import_id, :family_id, :challan_ref ],
                    name: "fk_tds_deductions_challan_ref"
    add_check_constraint :tds_deductions,
                         "challan_ref IS NULL OR btrim(challan_ref) <> ''",
                         name: "chk_tds_deductions_challan_ref_present"
    add_positive_row_constraint :tds_deductions
    add_non_negative_constraints :tds_deductions, %i[amount_paid tds_rate_pct tds_amount surcharge cess]
  end

  private
    def add_import_family_foreign_key(table_name)
      add_foreign_key table_name,
                      :tax_workbook_imports,
                      column: [ :tax_workbook_import_id, :family_id ],
                      primary_key: [ :id, :family_id ],
                      name: "fk_#{table_name}_import_family"
    end

    def add_positive_row_constraint(table_name)
      add_check_constraint table_name, "source_row_number > 0", name: "chk_#{table_name}_source_row_number_positive"
    end

    def add_non_negative_constraints(table_name, columns)
      columns.each do |column|
        add_check_constraint table_name,
                             "#{column} IS NULL OR #{column} >= 0",
                             name: "chk_#{table_name}_#{column}_non_negative"
      end
    end
end
