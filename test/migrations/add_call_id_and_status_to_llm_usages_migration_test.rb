# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261106120000_add_call_id_and_status_to_llm_usages")

# The backfill marks a row failed only when its error is present, as LlmUsage's own check has
# it; the schema changes roll back with the test's transaction.
class AddCallIdAndStatusToLlmUsagesMigrationTest < ActiveSupport::TestCase
  ERRORS = {
    "HTTP 500" => "failed",
    { "message" => "busy" } => "failed",
    [ "busy" ] => "failed",
    true => "failed",
    429 => "failed",
    "" => "succeeded",
    {} => "succeeded",
    [] => "succeeded",
    false => "succeeded",
    " " => "succeeded",
    "\t\n" => "succeeded",
    nil => "succeeded"
  }.freeze

  teardown { LlmUsage.reset_column_information }

  test "up marks failed exactly the rows whose error is present" do
    migrate(:down)
    ids = ERRORS.keys.map { insert_usage({ "error" => _1 }) }
    without_error = insert_usage({})

    migrate(:up)

    assert_equal ERRORS.values, ids.map { status_of(_1) }
    assert_equal "succeeded", status_of(without_error)
  end

  test "down then up restores the columns, the index and the constraint" do
    before = shape

    migrate(:down)
    assert_not connection.column_exists?(:llm_usages, :status)
    migrate(:up)

    assert_equal before, shape
  end

  private
    def connection = ActiveRecord::Base.connection

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { AddCallIdAndStatusToLlmUsages.new.migrate(direction) }
      LlmUsage.reset_column_information
    end

    def insert_usage(metadata)
      connection.select_value(<<~SQL)
        INSERT INTO llm_usages (family_id, provider, model, operation, prompt_tokens, completion_tokens, total_tokens, metadata, created_at, updated_at)
        VALUES (#{connection.quote(families(:dylan_family).id)}, 'openai', 'gpt-4.1', 'bill_setup', 1, 1, 2, #{connection.quote(metadata.to_json)}::jsonb, now(), now())
        RETURNING id
      SQL
    end

    def status_of(id) = connection.select_value("SELECT status FROM llm_usages WHERE id = #{connection.quote(id)}")

    def shape
      {
        columns: connection.columns(:llm_usages).map { [ _1.name, _1.sql_type, _1.default, _1.null ] }.sort,
        indexes: connection.indexes(:llm_usages).map(&:name).sort,
        constraints: connection.check_constraints(:llm_usages).map(&:name).sort
      }
    end
end
