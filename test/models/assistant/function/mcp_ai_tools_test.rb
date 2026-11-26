require "test_helper"
require Rails.root.join("db/migrate/20261126000000_add_source_import_id_to_imports")

# MCP's two AI-backed tools: declarations, the worker hand-off, and the durable
# answer a retried import gets.
class McpAiToolsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @pdf_import = imports(:pdf_processed)
    use_ai_routes
    SidekiqHealth.stubs(:current).returns(stub(reason: nil))
  end

  teardown { Import.reset_column_information }

  test "every AI tool declares a routed feature, a timeout and a busy message" do
    Assistant.function_classes.each do |fn_class|
      source = Rails.root.join("app/models/assistant/function/#{fn_class.name.demodulize.underscore}.rb").read
      calls_ai = source.match?(/\bAi\.availability\b|\bAi::(?:PdfReading|Generations)\b/)
      assert fn_class.ai_feature, "#{fn_class.name} calls AI without declaring its feature" if calls_ai
      next unless fn_class.ai_feature

      assert Ai::Routes.features.include?(fn_class.ai_feature), "#{fn_class.name} has an unrouted feature"
      assert Ai::ToolJob::TIMEOUTS.key?(fn_class.name), "#{fn_class.name} has no timeout"
      assert Ai::ToolJob::BUSY_MESSAGES.key?(fn_class.name), "#{fn_class.name} has no busy message"
    end
  end

  test "search stays listed when its AI feature is unavailable" do
    use_no_ai

    assert_includes Assistant.function_classes(@user), Assistant::Function::SearchFamilyFiles
    assert_not_includes Assistant.function_classes(@user), Assistant::Function::ImportBankStatement
  end

  test "the job runs the authorized function as the user and returns its result" do
    arguments = { "query" => "tax return" }
    Assistant::Function::SearchFamilyFiles.any_instance.expects(:call).with(arguments).returns(success: true, results: [])

    answer = nil
    perform_enqueued_jobs(only: Ai::ToolJob) do
      answer = Ai::ToolJob.run(Assistant::Function::SearchFamilyFiles, @user, arguments, timeout: 1)
    end

    assert_equal({ "success" => true, "results" => [] }, answer)
  end

  test "the job refuses a function the user is not authorized to call" do
    use_no_ai
    job = Ai::ToolJob.new(Assistant::Function::ImportBankStatement.name, @user, {})
    job.perform_now

    assert_equal "Unknown tool", Ai::SharedState.read("ai/tool_results/#{job.job_id}")["error"]
  end

  test "busy paths answer with each tool's message and enqueue nothing" do
    permits = 0
    SidekiqHealth.stubs(:current).returns(stub(reason: :ai_queues_not_polled))
    assert_no_enqueued_jobs(only: Ai::ToolJob) do
      answer = Ai::ToolJob.run(Assistant::Function::SearchFamilyFiles, @user, { "query" => "tax" }, timeout: 1)
      assert_equal "busy", answer["error"]
      assert_match(/try again/i, answer["message"])
    end

    SidekiqHealth.stubs(:current).returns(stub(reason: nil))
    Ai::ToolJob::WAITING.acquire(2)
    permits = 2
    assert_equal "busy", Ai::ToolJob.run(Assistant::Function::SearchFamilyFiles, @user, { "query" => "tax" }, timeout: 1)["error"]
    Ai::ToolJob::WAITING.release(permits)
    permits = 0

    { Assistant::Function::SearchFamilyFiles => /busy, try again/i,
      Assistant::Function::ImportBankStatement => /same pdf_import_id/ }.each do |fn_class, message|
      answer = Ai::ToolJob.run(fn_class, @user, { "query" => "tax", "pdf_import_id" => @pdf_import.id }, timeout: 0)

      assert_equal "busy", answer["error"], fn_class.name
      assert_match message, answer["message"]
      assert answer["tool_error"]
    end
  ensure
    Ai::ToolJob::WAITING.release(permits)
  end

  test "an import retry joins its job and completion clears the in-flight claim" do
    inflight = "ai/tool_inflight/import_bank_statement:#{@pdf_import.id}"
    arguments = { "pdf_import_id" => @pdf_import.id, "account_id" => @account.id }
    Ai::SharedState.write(inflight, "running-job", expires_in: 1.minute)
    Ai::SharedState.write("ai/tool_results/running-job",
                          { result: { success: true, already_imported: true, import_id: "draft-1" } },
                          expires_in: 1.minute)

    answer = nil
    assert_no_enqueued_jobs(only: Ai::ToolJob) do
      answer = Ai::ToolJob.run(Assistant::Function::ImportBankStatement, @user, arguments, timeout: 1)
    end
    assert_equal true, answer["already_imported"]
    assert_equal "draft-1", answer["import_id"]

    Ai::SharedState.delete(inflight)
    Assistant::Function::ImportBankStatement.any_instance.expects(:call).returns(success: true, import_id: "draft-1")
    perform_enqueued_jobs(only: Ai::ToolJob) do
      Ai::ToolJob.run(Assistant::Function::ImportBankStatement, @user, arguments, timeout: 1)
    end
    assert_nil Ai::SharedState.read(inflight)
  ensure
    Ai::SharedState.delete(inflight)
  end

  test "the unique index allows imports without a source but no duplicates with one" do
    source = imports(:pdf)
    TransactionImport.create!(family: source.family, source_import: source)

    assert_nothing_raised { TransactionImport.create!(family: source.family) }
    assert_raises(ActiveRecord::RecordNotUnique) do
      TransactionImport.create!(family: source.family, source_import: source)
    end
  end

  test "the source import column and index migrate up and back down" do
    before = schema_shape
    assert_equal [ "uuid", true ], before[:column]
    assert_equal [ [ "source_import_id" ], true, "(source_import_id IS NOT NULL)" ], before[:index]
    assert_equal [ "imports", "source_import_id" ], before[:foreign_key]

    migrate(:down)
    assert_nil schema_shape[:column]
    assert_nil schema_shape[:index]
    assert_nil schema_shape[:foreign_key]

    migrate(:up)
    assert_equal before, schema_shape
  end

  private
    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { AddSourceImportIdToImports.new.migrate(direction) }
      Import.reset_column_information
    end

    def schema_shape
      connection = ActiveRecord::Base.connection
      column = connection.columns(:imports).find { _1.name == "source_import_id" }
      index = connection.indexes(:imports).find { _1.name == "idx_imports_source_import_unique" }
      foreign_key = connection.foreign_keys(:imports).find { _1.column == "source_import_id" }

      {
        column: column && [ column.sql_type, column.null ],
        index: index && [ index.columns, index.unique, index.where ],
        foreign_key: foreign_key && [ foreign_key.to_table, foreign_key.column ]
      }
    end
end
