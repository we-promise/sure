# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"
require_relative "../../config/env_file_loader"

class EnvFileLoaderTest < ActiveSupport::TestCase
  test "loads base env var from matching _FILE path" do
    file = Tempfile.new("secret")
    file.write("super-secret\n")
    file.flush

    env = {
      "OPENAI_ACCESS_TOKEN_FILE" => file.path
    }

    Sure::EnvFileLoader.load!(env: env)

    assert_equal "super-secret", env["OPENAI_ACCESS_TOKEN"]
  ensure
    file.close!
  end

  test "direct env var takes precedence over matching _FILE value" do
    file = Tempfile.new("secret")
    file.write("file-secret\n")
    file.flush

    env = {
      "OPENAI_ACCESS_TOKEN" => "direct-secret",
      "OPENAI_ACCESS_TOKEN_FILE" => file.path
    }

    Sure::EnvFileLoader.load!(env: env)

    assert_equal "direct-secret", env["OPENAI_ACCESS_TOKEN"]
  ensure
    file.close!
  end

  test "warns and leaves base env var unset when file cannot be read" do
    env = {
      "OPENAI_ACCESS_TOKEN_FILE" => "/path/that/does/not/exist"
    }
    warning_output = StringIO.new

    Sure::EnvFileLoader.load!(env: env, warn_io: warning_output)

    assert_nil env["OPENAI_ACCESS_TOKEN"]
    assert_includes warning_output.string, "OPENAI_ACCESS_TOKEN_FILE"
  end

  test "denylisted variables are ignored" do
    file = Tempfile.new("secret")
    file.write("/tmp/custom-ca.pem\n")
    file.flush

    env = {
      "SSL_CA_FILE_FILE" => file.path
    }
    warning_output = StringIO.new

    Sure::EnvFileLoader.load!(env: env, warn_io: warning_output)

    assert_nil env["SSL_CA_FILE"]
    assert_includes warning_output.string, "SSL_CA_FILE_FILE"
    assert_includes warning_output.string, "not eligible"
  ensure
    file.close!
  end
end
