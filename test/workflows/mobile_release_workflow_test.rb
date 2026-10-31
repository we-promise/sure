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
      assert_equal "0.6.9\n", result[:metadata]
      assert_includes result[:output], "=0.6.9\n"
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

  private
    def workflow(name)
      YAML.load_file(Rails.root.join(".github/workflows/#{name}.yml"))
    end

    def execute(file, job, step_name, env)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "mobile"))
        File.write(File.join(dir, "mobile/pubspec.yaml"), "version: 0.6.9+42\n")
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
