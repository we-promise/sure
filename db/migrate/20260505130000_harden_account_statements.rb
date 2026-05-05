# frozen_string_literal: true

class HardenAccountStatements < ActiveRecord::Migration[7.2]
  def change
    add_column :account_statements, :content_sha256, :string
    add_index :account_statements,
              [ :family_id, :content_sha256 ],
              unique: true,
              where: "content_sha256 IS NOT NULL",
              name: "index_account_statements_on_family_content_sha256"

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
