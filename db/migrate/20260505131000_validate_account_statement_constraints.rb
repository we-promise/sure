# frozen_string_literal: true

class ValidateAccountStatementConstraints < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  CONSTRAINTS = %w[
    chk_account_statements_byte_size_max
    chk_account_statements_source
    chk_account_statements_upload_status
    chk_account_statements_review_status
    chk_account_statements_content_sha256
  ].freeze

  def change
    CONSTRAINTS.each do |constraint|
      validate_check_constraint :account_statements, name: constraint
    end
  end
end
