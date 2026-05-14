# frozen_string_literal: true

class CreateAccountStatements < ActiveRecord::Migration[7.2]
  def change
    create_table :account_statements, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :account, null: true, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :suggested_account, null: true, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.string :filename, null: false, limit: 255
      t.string :content_type, null: false, limit: 100
      t.bigint :byte_size, null: false
      t.string :checksum, null: false, limit: 64
      t.string :content_sha256
      t.string :source, null: false, default: "manual_upload"
      t.string :upload_status, null: false, default: "stored"

      t.string :institution_name_hint, limit: 200
      t.string :account_name_hint, limit: 200
      t.string :account_last4_hint, limit: 4
      t.date :period_start_on
      t.date :period_end_on
      t.decimal :opening_balance, precision: 19, scale: 4
      t.decimal :closing_balance, precision: 19, scale: 4
      t.string :currency, limit: 3

      t.decimal :parser_confidence, precision: 5, scale: 4
      t.decimal :match_confidence, precision: 5, scale: 4
      t.string :review_status, null: false, default: "unmatched"
      t.jsonb :sanitized_parser_output, null: false, default: {}

      t.timestamps

      t.index [ :family_id, :checksum ], name: "index_account_statements_on_family_checksum"
      t.index [ :family_id, :content_sha256 ],
              unique: true,
              where: "content_sha256 IS NOT NULL",
              name: "index_account_statements_on_family_content_sha256"
      t.index [ :family_id, :review_status ], name: "index_account_statements_on_family_review_status"
      t.index [ :account_id, :period_start_on, :period_end_on ], name: "index_account_statements_on_account_period"
      t.index [ :suggested_account_id, :review_status ], name: "index_account_statements_on_suggested_account_review"
    end

    add_check_constraint :account_statements, "byte_size > 0", name: "chk_account_statements_byte_size_positive"
    add_check_constraint :account_statements,
                         "char_length(filename) <= 255",
                         name: "chk_account_statements_filename_length"
    add_check_constraint :account_statements,
                         "char_length(content_type) <= 100",
                         name: "chk_account_statements_content_type_length"
    add_check_constraint :account_statements,
                         "char_length(checksum) <= 64",
                         name: "chk_account_statements_checksum_length"
    add_check_constraint :account_statements,
                         "institution_name_hint IS NULL OR char_length(institution_name_hint) <= 200",
                         name: "chk_account_statements_institution_hint_length"
    add_check_constraint :account_statements,
                         "account_name_hint IS NULL OR char_length(account_name_hint) <= 200",
                         name: "chk_account_statements_account_name_hint_length"
    add_check_constraint :account_statements,
                         "account_last4_hint IS NULL OR char_length(account_last4_hint) <= 4",
                         name: "chk_account_statements_account_last4_hint_length"
    add_check_constraint :account_statements,
                         "currency IS NULL OR char_length(currency) <= 3",
                         name: "chk_account_statements_currency_length"
    add_check_constraint :account_statements,
                         "period_start_on IS NULL OR period_end_on IS NULL OR period_start_on <= period_end_on",
                         name: "chk_account_statements_period_order"
    add_check_constraint :account_statements,
                         "parser_confidence IS NULL OR (parser_confidence >= 0 AND parser_confidence <= 1)",
                         name: "chk_account_statements_parser_confidence"
    add_check_constraint :account_statements,
                         "match_confidence IS NULL OR (match_confidence >= 0 AND match_confidence <= 1)",
                         name: "chk_account_statements_match_confidence"
    add_check_constraint :account_statements,
                         "byte_size <= 26214400",
                         name: "chk_account_statements_byte_size_max"
    add_check_constraint :account_statements,
                         "source IN ('manual_upload')",
                         name: "chk_account_statements_source"
    add_check_constraint :account_statements,
                         "upload_status IN ('stored', 'failed')",
                         name: "chk_account_statements_upload_status"
    add_check_constraint :account_statements,
                         "review_status IN ('unmatched', 'linked', 'rejected')",
                         name: "chk_account_statements_review_status"
    add_check_constraint :account_statements,
                         "content_sha256 IS NULL OR content_sha256 ~ '^[0-9a-f]{64}$'",
                         name: "chk_account_statements_content_sha256"
  end
end
