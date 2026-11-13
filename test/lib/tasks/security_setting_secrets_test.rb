# frozen_string_literal: true

require "test_helper"
require "rake"

class SecuritySettingSecretsTaskTest < ActiveSupport::TestCase
  OLD_SECRET_KEY_BASE = "old-secret-key-base-#{"e" * 64}"

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("security:rotate_setting_secrets")
    @task = Rake::Task["security:rotate_setting_secrets"]
    @task.reenable
  end

  teardown do
    Setting.openai_access_token = nil
  end

  test "re-encrypts settings saved under the old SECRET_KEY_BASE" do
    store_with_old_key("openai_access_token", "sk-old-key")

    output = with_env_overrides("OLD_SECRET_KEY_BASE" => OLD_SECRET_KEY_BASE) do
      capture_io { @task.invoke("0") }.first
    end

    result = JSON.parse(output.lines.last)
    assert result["ok"]
    assert_equal false, result["dry_run"]
    assert_equal "reencrypted", result["results"]["openai_access_token"]
    assert_equal "sk-old-key", Setting.openai_access_token
  end

  test "defaults to a dry run" do
    store_with_old_key("openai_access_token", "sk-old-key")

    output = with_env_overrides("OLD_SECRET_KEY_BASE" => OLD_SECRET_KEY_BASE) do
      capture_io { @task.invoke }.first
    end

    result = JSON.parse(output.lines.last)
    assert result["dry_run"]
    assert_equal "would_reencrypt", result["results"]["openai_access_token"]
    assert_not_equal "sk-old-key", Setting.openai_access_token
  end

  test "refuses to run without OLD_SECRET_KEY_BASE" do
    output = with_env_overrides("OLD_SECRET_KEY_BASE" => nil) do
      capture_io { assert_raises(SystemExit) { @task.invoke("0") } }.first
    end

    assert_equal "old_secret_key_base_missing", JSON.parse(output.lines.last)["error"]
  end

  test "refuses to run while SECRET_KEY_BASE is unchanged" do
    output = with_env_overrides("OLD_SECRET_KEY_BASE" => Rails.application.secret_key_base) do
      capture_io { assert_raises(SystemExit) { @task.invoke("0") } }.first
    end

    assert_equal "secret_key_base_unchanged", JSON.parse(output.lines.last)["error"]
  end

  test "fails when nothing decrypts with OLD_SECRET_KEY_BASE" do
    store_with_old_key("openai_access_token", "sk-old-key")

    output = with_env_overrides("OLD_SECRET_KEY_BASE" => "mistyped-#{OLD_SECRET_KEY_BASE}") do
      capture_io { assert_raises(SystemExit) { @task.invoke("0") } }.first
    end

    result = JSON.parse(output.lines.last)
    assert_equal "old_secret_key_base_did_not_match", result["error"]
    assert_equal [ "openai_access_token" ], result["not_decryptable"]
  end

  test "ignores surrounding whitespace in OLD_SECRET_KEY_BASE" do
    store_with_old_key("openai_access_token", "sk-old-key")

    with_env_overrides("OLD_SECRET_KEY_BASE" => " #{OLD_SECRET_KEY_BASE}\n") do
      capture_io { @task.invoke("0") }
    end

    assert_equal "sk-old-key", Setting.openai_access_token
  end

  private

    def store_with_old_key(var, plaintext)
      key = ActiveSupport::KeyGenerator.new(OLD_SECRET_KEY_BASE).generate_key("setting_encryption", 32)
      ciphertext = ActiveSupport::MessageEncryptor.new(key).encrypt_and_sign(plaintext)
      Setting.find_or_initialize_by(var: var).update!(value: ciphertext)
      Setting.clear_cache
    end
end
