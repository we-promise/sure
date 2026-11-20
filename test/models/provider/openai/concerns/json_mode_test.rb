require "test_helper"

class Provider::Openai::Concerns::JsonModeTest < ActiveSupport::TestCase
  class Subject
    include Provider::Openai::Concerns::JsonMode

    public :default_json_mode, :apply_json_mode
  end

  setup do
    @subject = Subject.new
    Setting.openai_json_mode = nil
  end

  teardown do
    Setting.openai_json_mode = nil
  end

  test "the shared constants stay in the order the settings UI offers them" do
    assert_equal %w[strict json_object none auto], Provider::Openai::Concerns::JsonMode::VALID_JSON_MODES
  end

  test "an explicit env mode wins over the stored setting" do
    Setting.openai_json_mode = "strict"

    with_env_overrides("LLM_JSON_MODE" => "none") do
      assert_equal "none", @subject.default_json_mode
    end
  end

  test "falls back to the stored setting when the env var is unset" do
    Setting.openai_json_mode = "json_object"

    with_env_overrides("LLM_JSON_MODE" => nil) do
      assert_equal "json_object", @subject.default_json_mode
    end
  end

  test "ignores an unrecognized env value and keeps looking" do
    Setting.openai_json_mode = "none"

    with_env_overrides("LLM_JSON_MODE" => "banana") do
      assert_equal "none", @subject.default_json_mode
    end
  end

  test "defaults to auto when nothing is configured" do
    with_env_overrides("LLM_JSON_MODE" => nil) do
      assert_equal "auto", @subject.default_json_mode
    end
  end

  test "none omits response_format so strict runtimes are not rejected" do
    params = { model: "local-model" }

    @subject.apply_json_mode(params, mode: "none")

    assert_not params.key?(:response_format)
  end

  test "json_object asks for an object" do
    params = {}

    @subject.apply_json_mode(params, mode: "json_object")

    assert_equal({ type: "json_object" }, params[:response_format])
  end

  test "auto degrades to json_object because it has no fallback strategy of its own" do
    params = {}

    @subject.apply_json_mode(params, mode: "auto")

    assert_equal({ type: "json_object" }, params[:response_format])
  end

  test "strict uses the supplied schema" do
    params = {}
    schema = { name: "things", strict: true, schema: { type: "object" } }

    @subject.apply_json_mode(params, mode: "strict", schema: schema)

    assert_equal({ type: "json_schema", json_schema: schema }, params[:response_format])
  end

  test "strict without a schema degrades to json_object" do
    params = {}

    @subject.apply_json_mode(params, mode: "strict")

    assert_equal({ type: "json_object" }, params[:response_format])
  end

  test "applying a mode preserves the params it was handed" do
    params = { model: "local-model", messages: [ { role: "user", content: "hi" } ] }

    returned = @subject.apply_json_mode(params, mode: "none")

    assert_same params, returned
    assert_equal "local-model", returned[:model]
  end
end
