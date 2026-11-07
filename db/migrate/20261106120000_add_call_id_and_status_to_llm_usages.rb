# One llm_usages row per request, grouped per call. Rows written before this, and rows the
# per-provider usage recorders write, have no call_id: each counts as a call of one request.
class AddCallIdAndStatusToLlmUsages < ActiveRecord::Migration[8.1]
  STATUSES = %w[succeeded failed cancelled].freeze

  def up
    add_column :llm_usages, :call_id, :uuid
    add_column :llm_usages, :status, :string, null: false, default: "succeeded"
    add_index :llm_usages, :call_id
    add_check_constraint :llm_usages, "status IN (#{STATUSES.map { "'#{_1}'" }.join(", ")})", name: "chk_llm_usages_status"

    # Today's recorders mark a failed request by putting its error in metadata; a null or blank
    # error was never shown as a failure, and isn't one now (LlmUsage checks `present?`).
    execute "UPDATE llm_usages SET status = 'failed' WHERE NULLIF(BTRIM(metadata->>'error'), '') IS NOT NULL"
  end

  def down
    remove_check_constraint :llm_usages, name: "chk_llm_usages_status"
    remove_index :llm_usages, :call_id
    remove_column :llm_usages, :status
    remove_column :llm_usages, :call_id
  end
end
