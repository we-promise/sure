require "test_helper"
require "open3"
require "tmpdir"
require "yaml"

class MobileReleaseWorkflowTest < ActiveSupport::TestCase
  test "Android preserves alpha identity while iOS uses the numeric version" do
    %w[2026.10.31-alpha 2026.10.31].each do |version|
      { "build-android" => version, "build-ios" => "2026.10.31" }.each do |job, name|
        result = resolve("flutter-build", job, ref: "v#{version}")
        assert_equal "#{version}\n", result[:metadata]
        assert_includes result[:output], "SURE_BUILD_NAME=#{name}\n"
      end
      result = resolve("ios-testflight", "build-and-upload", ref: "v#{version}")
      assert_equal "#{version}\n", result[:metadata]
      assert_includes result[:output], "ios_version=2026.10.31\n"
    end
  end

  test "mobile-only tag and manual callers pass the selected version to every build" do
    caller_jobs = workflow("mobile-release").fetch("jobs")
    %w[build testflight].each do |job|
      assert_includes caller_jobs.fetch(job).fetch("needs"), "prepare_release"
      assert_equal "${{ needs.prepare_release.outputs.release_version }}", caller_jobs.fetch(job).fetch("with").fetch("app_version")
    end
    [ [ "mobile-v2026.11.1-alpha", "v2026.11.1-alpha" ],
      [ "main", "v2026.11.1-p202611011234" ] ].each do |ref, selected|
      [ [ "flutter-build", "build-android", selected.delete_prefix("v") ],
        [ "flutter-build", "build-ios", "2026.11.1" ],
        [ "ios-testflight", "build-and-upload", "2026.11.1" ] ].each do |file, job, name|
        result = resolve(file, job, ref: ref, selected: selected)
        assert_equal "#{selected.delete_prefix('v')}\n", result[:metadata]
        assert_includes result[:output], "=#{name}\n"
      end
    end
  end

  test "standalone branch builds retain pubspec fallback" do
    [ [ "flutter-build", "build-android" ], [ "flutter-build", "build-ios" ],
      [ "ios-testflight", "build-and-upload" ] ].each do |file, job|
      result = resolve(file, job, ref: "main")
      assert_equal "0.0.0-dev\n", result[:metadata]
      name = job == "build-android" ? "0.0.0-dev" : "0.0.0"
      assert_includes result[:output], "=#{name}\n"
    end
  end

  test "automatic TestFlight accepts only canonical calendar tags" do
    %w[v2026.10.31 v2026.10.31-alpha v2028.2.29-alpha].each do |ref|
      assert eligible?("push", "refs/tags/#{ref}"), ref
    end
    %w[v0.7.7-alpha.2 v2026.10.31-beta v2026.10.31-rc.1 v2026.10.31-alpha.2
      v2026.02.1 v2026.2.29 v2026.4.31 v2026.13.1 vgarbage].each do |ref|
      assert_not eligible?("push", "refs/tags/#{ref}"), ref
    end
    assert_not eligible?("push", "refs/heads/main")
    job = workflow("ios-testflight").fetch("jobs").fetch("build-and-upload")
    assert_includes job.fetch("needs"), "validate-release"
    assert_equal "needs.validate-release.outputs.eligible == 'true'", job.fetch("if")
  end

  test "TestFlight preserves explicit mobile callers and non-push events" do
    assert eligible?("push", "refs/tags/mobile-v2026.11.1-alpha", "v2026.11.1-alpha")
    assert_not eligible?("push", "refs/tags/mobile-v2026.11.1-alpha")
    assert_not eligible?("push", "refs/tags/v2026.11.1-beta", "v2026.11.1")
    assert eligible?("workflow_dispatch", "refs/heads/main")
    assert eligible?("workflow_dispatch", "refs/heads/main", "v2026.11.1-p202611011234")
  end

  test "Android build numbers advance across days years and retries of the same tag" do
    timestamps = %w[2026-11-03T23:59:59Z 2026-11-04T00:00:00Z 2026-12-31T23:59:59Z 2027-01-01T00:00:00Z]
    codes = timestamps.map do |timestamp|
      output, status, env = android_number(Time.iso8601(timestamp).to_i)
      assert status.success?, output
      code = env.delete_prefix("SURE_BUILD_NUMBER=").to_i
      assert_operator code, :>, 20260402
      assert_operator code, :<=, 2100000000
      code
    end
    assert_equal codes.sort.uniq, codes
    assert_equal 1, codes[1] - codes[0]
    assert_equal 1, codes[3] - codes[2]
  end

  test "Android rejects legacy or overflowing version codes" do
    [ 1577836800, 1577836800 + 20260402, 1577836800 + 2100000001 ].each do |timestamp|
      output, status, env = android_number(timestamp)
      assert_not status.success?, output
      assert_includes output, "outside the supported range"
      assert_empty env
    end
    output, status, = android_number(1577836800 + 2100000000)
    assert status.success?, output
  end

  test "Android APK and AAB commands receive the same dynamic build number" do
    job = workflow("flutter-build").fetch("jobs").fetch("build-android")
    assert_equal({ "group" => "android-build-number", "cancel-in-progress" => false, "queue" => "max" }, job.fetch("concurrency"))
    %w[true false].each do |signed|
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "flutter"), "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$COMMAND_LOG\"\n")
        FileUtils.chmod(0755, File.join(dir, "flutter"))
        env = { "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "COMMAND_LOG" => File.join(dir, "commands"),
                "SURE_BUILD_NAME" => "2026.11.3-alpha", "SURE_BUILD_NUMBER" => "216000001" }
        [ "Build APK (Release)", "Build App Bundle (Release)" ].each do |name|
          script = job.fetch("steps").find { |step| step["name"] == name }.fetch("run")
          script = script.gsub("${{ steps.check_secrets.outputs.has_keystore }}", signed)
          output, status = Open3.capture2e(env, "bash", "-e", "-c", script)
          assert status.success?, output
        end
        commands = File.readlines(env.fetch("COMMAND_LOG"), chomp: true)
        mode = signed == "true" ? "release" : "debug"
        assert_equal [ "build apk --#{mode} --build-name=2026.11.3-alpha --build-number=216000001",
                       "build appbundle --release --build-name=2026.11.3-alpha --build-number=216000001" ], commands
      end
    end
  end

  test "Android release bundle steps require a keystore" do
    steps = workflow("flutter-build").fetch("jobs").fetch("build-android").fetch("steps")
    [ "Build App Bundle (Release)", "Upload AAB artifact" ].each do |name|
      step = steps.find { |candidate| candidate["name"] == name }
      assert_equal "steps.check_secrets.outputs.has_keystore == 'true'", step.fetch("if")
    end
  end

  test "unsigned iOS packaging overrides the development build number" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "flutter"), "#!/bin/bash\nprintf '%s\\n' \"$*\"\n")
      FileUtils.chmod(0755, File.join(dir, "flutter"))
      script = workflow("flutter-build").fetch("jobs").fetch("build-ios").fetch("steps")
        .find { |step| step["name"] == "Build iOS (No Code Signing)" }.fetch("run")
      %w[0.0.0 2026.11.4].each do |name|
        output, status = Open3.capture2e({ "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "SURE_BUILD_NAME" => name }, "bash", "-e", "-c", script)
        assert status.success?, output
        assert_equal "build ios --release --no-codesign --build-name=#{name} --build-number=1\n", output
      end
    end
  end

  private
    def android_number(timestamp)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "date"), "#!/bin/bash\necho #{timestamp}\n")
        FileUtils.chmod(0755, File.join(dir, "date"))
        env_path = File.join(dir, "env")
        script = workflow("flutter-build").fetch("jobs").fetch("build-android").fetch("steps")
          .find { |step| step["name"] == "Resolve Android build number" }.fetch("run")
        output, status = Open3.capture2e({ "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "GITHUB_ENV" => env_path,
          "GITHUB_REF_NAME" => "v2026.11.3-alpha" }, "bash", "-c", script)
        [ output, status, File.exist?(env_path) ? File.read(env_path).strip : "" ]
      end
    end

    def workflow(name)
      YAML.load_file(Rails.root.join(".github/workflows/#{name}.yml"))
    end

    def execute(file, job, step_name, env)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "mobile"))
        FileUtils.cp(Rails.root.join("mobile/pubspec.yaml"), File.join(dir, "mobile/pubspec.yaml"))
        output_path = File.join(dir, "output")
        env = env.merge("GITHUB_ENV" => output_path, "GITHUB_OUTPUT" => output_path)
        script = workflow(file).fetch("jobs").fetch(job).fetch("steps").find { |step| step["name"] == step_name }.fetch("run")
        output, status = Open3.capture2e(env, "bash", "-c", script, chdir: dir)
        assert status.success?, output
        metadata_path = File.join(dir, ".sure-version")
        { output: File.read(output_path), metadata: File.exist?(metadata_path) ? File.read(metadata_path) : nil }
      end
    end

    def resolve(file, job, ref:, selected: "")
      execute(file, job, "Resolve app version", "GITHUB_REF_TYPE" => ref == "main" ? "branch" : "tag",
        "GITHUB_REF_NAME" => ref, "APP_VERSION_INPUT" => selected)
    end

    def eligible?(event, ref, selected = "")
      execute("ios-testflight", "validate-release", "Validate automatic release tag",
        "GITHUB_EVENT_NAME" => event, "GITHUB_REF" => ref, "APP_VERSION_INPUT" => selected)[:output].include?("eligible=true\n")
    end
end
