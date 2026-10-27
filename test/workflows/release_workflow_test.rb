require "test_helper"
require "open3"
require "tmpdir"
require "yaml"

class ReleaseWorkflowTest < ActiveSupport::TestCase
  setup do
    skip "Release shell steps target Linux runners with GNU date" unless RUBY_PLATFORM.include?("linux")
  end

  test "canonical tag publishes while its compatibility alias is a no-op" do
    with_repo do |dir|
      success, output = resolve(dir, "2026.10.31")
      assert success
      %w[release=true compatibility_version=0.7.6 type=raw,value=stable type=raw,value=0.7.6].each { |line| assert_includes output, line }
      success, output = resolve(dir, "2026.10.31", ref: "refs/tags/v0.7.6")
      assert success
      assert_includes output, "publish=false"
      assert_includes output, "release=false"
      assert_not resolve(dir, "2026.10.31", ref: "refs/tags/v0.7.7").first
    end
  end

  test "alpha publishes latest while beta and rc do not promote stable" do
    with_repo do |dir|
      %w[2026.11.2-alpha 2026.11.2-alpha.12 2026.10.31-beta 2026.10.31-rc.2].each do |version|
        success, output = resolve(dir, version)
        assert success, version
        assert_includes output, "release=true"
        assert_not_includes output, "type=raw,value=stable"
        assert_not_includes output, "type=raw,value=0.7.6"
        assert_includes output, "type=raw,value=latest" if version.include?("alpha")
      end
    end
  end

  test "invalid dates padding and hotfix modifiers are rejected" do
    with_repo do |dir|
      %w[2026.11.02 2026.11.0 2026.2.29 2026.4.31 2026.10.31-hotfix.1 2026.10.31-1].each do |version|
        assert_not resolve(dir, version).first, version
      end
    end
  end

  test "non-release builds and January do not emit compatibility tags" do
    with_repo do |dir|
      [ "push", "schedule", "workflow_dispatch" ].each do |event|
        success, output = resolve(dir, "2026.10.31", event: event, ref: "refs/heads/main")
        assert success
        assert_includes output, "release=false"
        assert_not_includes output, "type=raw"
        assert_includes output, "type=schedule,pattern=nightly" if event == "schedule"
      end
      success, output = resolve(dir, "2027.1.1", extra_env: { "COMPATIBILITY_RELEASE" => "2027.1.1" })
      assert success
      assert_not_includes output, "type=raw,value=0.7.6"
      assert_includes output, "type=raw,value=stable"
    end
  end

  test "non-force alias step accepts retries and annotated tags but not other commits" do
    with_repo do |dir|
      remote = File.join(dir, "remote.git")
      git!(dir, "init", "--bare", remote)
      git!(dir, "remote", "add", "origin", remote)
      2.times { assert run_step(dir, "merge", "compatibility", "COMPATIBILITY_VERSION" => "0.7.6").first }
      git!(dir, "tag", "-a", "v0.7.7", "-m", "annotated")
      git!(dir, "push", "origin", "v0.7.7")
      assert run_step(dir, "merge", "compatibility", "COMPATIBILITY_VERSION" => "0.7.7").first
      original = git!(remote, "rev-parse", "v0.7.6")
      git!(dir, "commit", "--allow-empty", "-m", "different")
      success, output = run_step(dir, "merge", "compatibility", "COMPATIBILITY_VERSION" => "0.7.6")
      assert_not success
      assert_includes output, "refusing to move"
      assert_equal original, git!(remote, "rev-parse", "v0.7.6")
    end
  end

  private
    def workflow
      @workflow ||= YAML.load_file(Rails.root.join(".github/workflows/publish.yml"))
    end

    def run_step(dir, job, id, env)
      script = workflow.fetch("jobs").fetch(job).fetch("steps").find { |step| step["id"] == id }.fetch("run")
      output, status = Open3.capture2e(env, "bash", "-c", script, chdir: dir)
      [ status.success?, output ]
    end

    def resolve(dir, version, event: "push", ref: "refs/tags/v#{version}", extra_env: {})
      File.write(File.join(dir, ".sure-version"), version)
      path = File.join(dir, "output")
      File.write(path, "")
      env = { "COMPATIBILITY_RELEASE" => "2026.10.31", "COMPATIBILITY_VERSION" => "0.7.6",
        "GITHUB_EVENT_NAME" => event,
        "GITHUB_REF" => ref, "GITHUB_OUTPUT" => path }.merge(extra_env)
      success, error = run_step(dir, "prepare", "release", env)
      [ success, File.read(path) + error ]
    end

    def with_repo
      Dir.mktmpdir do |dir|
        git!(dir, "init")
        git!(dir, "config", "user.email", "test@example.com")
        git!(dir, "config", "user.name", "Release Test")
        git!(dir, "commit", "--allow-empty", "-m", "candidate")
        yield dir
      end
    end

    def git!(dir, *args)
      output, status = Open3.capture2e("git", *args, chdir: dir)
      assert status.success?, output
      output
    end
end
