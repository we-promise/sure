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
    arguments = { "pdf_import_id" => @pdf_import.id, "account_id" => @account.id }
    inflight = Ai::ToolJob.inflight_key(Assistant::Function::ImportBankStatement.name, @user, arguments)
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

  test "a different user cannot join another caller's running import" do
    fn_class = Assistant::Function::ImportBankStatement
    arguments = { "pdf_import_id" => @pdf_import.id, "account_id" => @account.id }
    first_key = Ai::ToolJob.inflight_key(fn_class.name, @user, arguments)
    Ai::SharedState.write(first_key, "running-job", expires_in: 1.minute)
    Ai::SharedState.write("ai/tool_results/running-job",
                          { result: { success: true, import_id: "first-callers-draft" } },
                          expires_in: 1.minute)

    member = users(:family_member)
    fn_class.any_instance.expects(:call).with(arguments).returns(success: true, import_id: "member-draft")

    answer = nil
    perform_enqueued_jobs(only: Ai::ToolJob) do
      answer = Ai::ToolJob.run(fn_class, member, arguments, timeout: 1)
    end

    assert_equal "member-draft", answer["import_id"]
    assert_nil Ai::SharedState.read(Ai::ToolJob.inflight_key(fn_class.name, member, arguments))
    assert_equal "running-job", Ai::SharedState.read(first_key)
  ensure
    Ai::SharedState.delete(first_key) if first_key
  end

  test "a different account_id cannot join a running import" do
    fn_class = Assistant::Function::ImportBankStatement
    arguments = { "pdf_import_id" => @pdf_import.id, "account_id" => @account.id }
    other_arguments = arguments.merge("account_id" => accounts(:credit_card).id)
    first_key = Ai::ToolJob.inflight_key(fn_class.name, @user, arguments)
    Ai::SharedState.write(first_key, "running-job", expires_in: 1.minute)
    Ai::SharedState.write("ai/tool_results/running-job",
                          { result: { success: true, import_id: "first-callers-draft" } },
                          expires_in: 1.minute)

    fn_class.any_instance.expects(:call).with(other_arguments).returns(success: true, import_id: "other-account-draft")

    answer = nil
    perform_enqueued_jobs(only: Ai::ToolJob) do
      answer = Ai::ToolJob.run(fn_class, @user, other_arguments, timeout: 1)
    end

    assert_equal "other-account-draft", answer["import_id"]
    assert_equal "running-job", Ai::SharedState.read(first_key)
  ensure
    Ai::SharedState.delete(first_key) if first_key
  end

  test "a joining caller is revalidated before it gets the running job's result" do
    fn_class = Assistant::Function::ImportBankStatement
    arguments = { "pdf_import_id" => @pdf_import.id, "account_id" => @account.id }
    inflight = Ai::ToolJob.inflight_key(fn_class.name, @user, arguments)
    Ai::SharedState.write(inflight, "running-job", expires_in: 1.minute)
    Ai::SharedState.write("ai/tool_results/running-job",
                          { result: { success: true, import_id: "first-callers-draft" } },
                          expires_in: 1.minute)
    @pdf_import.destroy!

    answer = Ai::ToolJob.run(fn_class, @user, arguments, timeout: 1)

    assert_equal "The tool failed to run", answer["error"]
    assert answer["tool_error"]
    assert_equal "running-job", Ai::SharedState.read(inflight), "the first caller's claim is left alone"
  ensure
    Ai::SharedState.delete(inflight) if inflight
  end

  test "a caller whose tool is no longer listed cannot join a running job" do
    fn_class = Assistant::Function::ImportBankStatement
    arguments = { "pdf_import_id" => @pdf_import.id, "account_id" => @account.id }
    inflight = Ai::ToolJob.inflight_key(fn_class.name, @user, arguments)
    Ai::SharedState.write(inflight, "running-job", expires_in: 1.minute)
    Ai::SharedState.write("ai/tool_results/running-job",
                          { result: { success: true, import_id: "first-callers-draft" } },
                          expires_in: 1.minute)
    use_no_ai

    answer = Ai::ToolJob.run(fn_class, @user, arguments, timeout: 1)

    assert_equal "The tool failed to run", answer["error"]
  ensure
    Ai::SharedState.delete(inflight) if inflight
  end

  test "a refused enqueue clears the claim and fails instead of polling" do
    fn_class = Assistant::Function::ImportBankStatement
    arguments = { "pdf_import_id" => @pdf_import.id, "account_id" => @account.id }
    inflight = Ai::ToolJob.inflight_key(fn_class.name, @user, arguments)
    Ai::ToolJob.any_instance.stubs(:enqueue).returns(false)

    answer = Ai::ToolJob.run(fn_class, @user, arguments, timeout: 1)

    assert_equal "The tool failed to run", answer["error"]
    assert answer["tool_error"]
    assert_nil Ai::SharedState.read(inflight)
  end

  test "an enqueue error clears the claim and fails instead of polling" do
    fn_class = Assistant::Function::ImportBankStatement
    arguments = { "pdf_import_id" => @pdf_import.id, "account_id" => @account.id }
    inflight = Ai::ToolJob.inflight_key(fn_class.name, @user, arguments)
    Ai::ToolJob.any_instance.stubs(:enqueue).raises(ActiveJob::EnqueueError, "refused")

    answer = Ai::ToolJob.run(fn_class, @user, arguments, timeout: 1)

    assert_equal "The tool failed to run", answer["error"]
    assert answer["tool_error"]
    assert_nil Ai::SharedState.read(inflight)
  end

  test "the tool call runs inside a stable AI call context" do
    fn_class = Assistant::Function::SearchFamilyFiles
    arguments = { "query" => "tax return" }
    correlation = Ai::ToolJob.correlation_id(fn_class.name, arguments)

    fn_class.any_instance.expects(:call).with do |received|
      assert_equal correlation, Ai::CallContext.correlation_id
      received == arguments
    end.returns(success: true, results: [])

    answer = nil
    perform_enqueued_jobs(only: Ai::ToolJob) do
      answer = Ai::ToolJob.run(fn_class, @user, arguments, timeout: 1)
    end

    assert_equal({ "success" => true, "results" => [] }, answer)
    assert_equal correlation, Ai::ToolJob.correlation_id(fn_class.name, arguments.reverse_each.to_h)
  end

  test "a failed tool call logs the same correlation id" do
    fn_class = Assistant::Function::SearchFamilyFiles
    arguments = { "query" => "tax return" }
    correlation = Ai::ToolJob.correlation_id(fn_class.name, arguments)
    fn_class.any_instance.expects(:call).with(arguments).raises(StandardError, "boom")

    logged = []
    Rails.logger.stubs(:error).with { |message| logged << message; true }

    answer = nil
    perform_enqueued_jobs(only: Ai::ToolJob) do
      answer = Ai::ToolJob.run(fn_class, @user, arguments, timeout: 1)
    end

    assert_equal "The tool failed to run", answer["error"]
    assert logged.any? { _1.include?("correlation: #{correlation}") }, "the failure log carries the call's id: #{logged.inspect}"
  end

  test "all unavailable-worker reasons answer busy" do
    [ :ai_queues_not_polled, :no_worker_processes, :stale_heartbeat ].each do |reason|
      SidekiqHealth.stubs(:current).returns(stub(reason: reason))

      assert_no_enqueued_jobs(only: Ai::ToolJob) do
        answer = Ai::ToolJob.run(Assistant::Function::SearchFamilyFiles, @user, { "query" => "tax" }, timeout: 1)
        assert_equal "busy", answer["error"], reason
        assert_match(/try again/i, answer["message"])
      end
    end
  end

  test "two initial calls claim atomically and enqueue one job" do
    fn_class = Assistant::Function::ImportBankStatement
    arguments = { "pdf_import_id" => @pdf_import.id, "account_id" => @account.id }
    inflight = Ai::ToolJob.inflight_key(fn_class.name, @user, arguments)

    first_thread = Thread.new { Ai::ToolJob.run(fn_class, @user, arguments, timeout: 3) }
    Timeout.timeout(2) { sleep 0.01 until Ai::SharedState.read(inflight) }
    job_id = Ai::SharedState.read(inflight)
    writer = Thread.new do
      sleep 0.05
      Ai::SharedState.write("ai/tool_results/#{job_id}",
                            { result: { success: true, import_id: "draft-1" } },
                            expires_in: 1.minute)
    end
    second_answer = Ai::ToolJob.run(fn_class, @user, arguments, timeout: 3)
    first_answer = first_thread.value
    writer.join

    assert_equal "draft-1", first_answer["import_id"]
    assert_equal "draft-1", second_answer["import_id"]
    assert_enqueued_jobs 1, only: Ai::ToolJob
  ensure
    [ first_thread, writer ].compact.each { |thread| thread.kill if thread.alive? }
    [ first_thread, writer ].compact.each(&:join)
  end

  test "the in-flight claim is set only once" do
    key = "ai/tool_inflight/test-claim"

    assert_nil Ai::SharedState.claim(key, "first", expires_in: 1.minute)
    assert_equal "first", Ai::SharedState.claim(key, "second", expires_in: 1.minute)
  end

  test "the unique index allows imports without a source but no duplicates with one" do
    source = imports(:pdf)
    TransactionImport.create!(family: source.family, source_import: source)

    assert_nothing_raised { TransactionImport.create!(family: source.family) }
    assert_raises(ActiveRecord::RecordNotUnique) do
      TransactionImport.create!(family: source.family, source_import: source)
    end
  end

  test "deleting a source import keeps its derived import" do
    source = imports(:pdf)
    derived = TransactionImport.create!(family: source.family, source_import: source)

    source.destroy!

    assert derived.reload.persisted?
    assert_nil derived.source_import_id
  end

  test "deleting a family with a derived import does not violate the source foreign key" do
    family = Family.create!(name: "Tool imports family", currency: "USD", locale: "en")
    source = PdfImport.create!(family:, document_type: "bank_statement")
    TransactionImport.create!(family:, source_import: source)

    assert_nothing_raised { family.destroy! }
    assert_equal 0, Import.where(family_id: family.id).count
  end

  test "the source import column and index migrate up and back down" do
    before = schema_shape
    assert_equal [ "uuid", true ], before[:column]
    assert_equal [ [ "source_import_id" ], true, "(source_import_id IS NOT NULL)" ], before[:index]
    assert_equal [ "imports", "source_import_id", :nullify ], before[:foreign_key]

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
        foreign_key: foreign_key && [ foreign_key.to_table, foreign_key.column, foreign_key.on_delete ]
      }
    end
end
