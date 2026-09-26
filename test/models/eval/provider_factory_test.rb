require "test_helper"

class Eval::ProviderFactoryTest < ActiveSupport::TestCase
  test "passes per-run temperature only when set" do
    Provider::Openai.expects(:new).with(
      "test-token", uri_base: nil, model: "gpt-4.1", eval_temperature: 0.0
    )
    Eval::ProviderFactory.build(
      provider: "openai", model: "gpt-4.1",
      config: { "access_token" => "test-token", "temperature" => 0 }
    )
  end

  test "rejects out-of-range temperature" do
    assert_raises(Eval::ProviderFactory::Error) do
      Eval::ProviderFactory.build(
        provider: "openai", model: "gpt-4.1",
        config: { "access_token" => "test-token", "temperature" => 3 }
      )
    end
  end

  test "does not change production defaults for runs without overrides" do
    Provider::Openai.expects(:new).with("test-token", uri_base: nil, model: "gpt-4.1")
    Eval::ProviderFactory.build(
      provider: "openai", model: "gpt-4.1", config: { "access_token" => "test-token" }
    )
  end
end
