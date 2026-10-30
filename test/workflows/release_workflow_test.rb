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
      success, output = resolve(dir, "2026.10.30-alpha")
      assert success
      %w[release=true compatibility_version=0.7.7-alpha.2 type=raw,value=latest type=raw,value=0.7.7-alpha.2].each { |line| assert_includes output, line }
      success, output = resolve(dir, "2026.10.28", ref: "refs/tags/v0.7.7-alpha.2")
      assert success
      assert_includes output, "publish=false"
      assert_includes output, "release=false"
      assert_not resolve(dir, "2026.10.28", ref: "refs/tags/vgarbage").first
    end
  end

  test "date-only alphas publish latest and clean dates publish stable" do
    with_repo do |dir|
      { "2026.11.2-alpha" => "latest", "2026.11.2" => "stable" }.each do |version, channel|
        success, output = resolve(dir, version)
        assert success, version
        assert_includes output, "release=true"
        assert_includes output, "type=raw,value=#{channel}"
        assert_not_includes output, "type=raw,value=#{channel == 'latest' ? 'stable' : 'latest'}"
      end
    end
  end

  test "compatibility channel follows release dates without matching other channels" do
    with_repo do |dir|
      %w[alpha stable].each do |phase|
        suffix = phase == "stable" ? "" : "-#{phase}"
        version = "2026.11.2#{suffix}"
        legacy = phase == "stable" ? "0.7.7" : "0.7.7-alpha.3"
        success, output = resolve(dir, version, extra_env: { "COMPATIBILITY_CHANNEL" => phase, "COMPATIBILITY_VERSION" => legacy })
        assert success
        assert_includes output, "compatibility_version=#{legacy}"
      end
      %w[2026.10.31-alpha 2026.11.2-alpha 2026.12.31-alpha].each do |version|
        success, output = resolve(dir, version, extra_env: { "BUILD_DATE" => "2027.1.2" })
        assert success
        assert_includes output, "version=#{version}"
        assert_includes output, "compatibility_version=0.7.7-alpha.2"
      end
      %w[2026.10.30 2026.10.31].each do |version|
        success, output = resolve(dir, version)
        assert success
        assert_not_includes output, "type=raw,value=0.7.7"
      end
      success, output = resolve(dir, "2026.10.30-alpha", ref: "refs/heads/main",
        extra_env: { "BUILD_DATE" => "2026.10.30", "GITHUB_RUN_NUMBER" => "2" })
      assert success
      assert_not_includes output, "compatibility_version=0.7.7"
    end
  end

  test "invalid dates and all canonical suffixes other than alpha are rejected" do
    with_repo do |dir|
      %w[2026.11.02 2026.11.0 2026.2.29 2026.4.31 2026.10.28-hotfix.1 2026.10.28-1 2026.10.30-alpha.2 2026.10.30-alpha.0 2026.10.30-beta 2026.10.30-rc.1].each do |version|
        assert_not resolve(dir, version).first, version
      end
    end
  end

  test "non-release builds and January do not emit compatibility tags" do
    with_repo do |dir|
      [ "push", "schedule", "workflow_dispatch" ].each do |event|
        success, output = resolve(dir, "2026.10.28", event: event, ref: "refs/heads/main")
        assert success
        assert_includes output, "release=false"
        assert_includes output, "version=2026.10.28-alpha"
        assert_not_includes output, "type=raw"
        assert_includes output, "type=schedule,pattern=nightly" if event == "schedule"
      end
      success, output = resolve(dir, "2027.1.1", extra_env: { "COMPATIBILITY_CHANNEL" => "stable" })
      assert success
      assert_not_includes output, "type=raw,value=0.7.7"
      assert_includes output, "type=raw,value=stable"
    end
  end

  test "non-force alias step accepts retries and annotated tags but not other commits" do
    with_repo do |dir|
      remote = File.join(dir, "remote.git")
      git!(dir, "init", "--bare", remote)
      git!(dir, "remote", "add", "origin", remote)
      2.times { assert run_step(dir, "merge", "compatibility", "COMPATIBILITY_VERSION" => "0.7.7-alpha.2").first }
      git!(dir, "tag", "-a", "v0.7.7", "-m", "annotated")
      git!(dir, "push", "origin", "v0.7.7")
      assert run_step(dir, "merge", "compatibility", "COMPATIBILITY_VERSION" => "0.7.7").first
      original = git!(remote, "rev-parse", "v0.7.7-alpha.2")
      git!(dir, "commit", "--allow-empty", "-m", "different")
      success, output = run_step(dir, "merge", "compatibility", "COMPATIBILITY_VERSION" => "0.7.7-alpha.2")
      assert_not success
      assert_includes output, "refusing to move"
      assert_equal original, git!(remote, "rev-parse", "v0.7.7-alpha.2")
    end
  end

  test "release tag wins over build date and is embedded without a tracked file" do
    with_repo do |dir|
      success, output = resolve(dir, "2026.10.28", extra_env: { "BUILD_DATE" => "2026.11.1" })
      assert success
      assert_includes output, "version=2026.10.28"
      assert_not File.exist?(File.join(dir, ".sure-version"))
      assert run_step(dir, "build", "version_file", "VERSION" => "2026.10.28").first
      assert_equal "2026.10.28\n", File.read(File.join(dir, ".sure-version"))
    end
  end

  test "workflow creation date drives branch builds across month and year boundaries" do
    with_repo do |dir|
      gh = File.join(dir, "gh")
      File.write(gh, "#!/bin/sh\nprintf '%s\\n' \"$CREATED_AT\"\n")
      File.chmod(0755, gh)
      env_file = File.join(dir, "env")
      { "2026-11-01T00:00:01Z" => "2026.11.1", "2027-01-01T00:00:01Z" => "2027.1.1" }.each do |created, date|
        File.write(env_file, "")
        env = { "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "CREATED_AT" => created,
          "GITHUB_REPOSITORY" => "test/repo", "GITHUB_RUN_ID" => "42", "GITHUB_ENV" => env_file }
        2.times { assert run_step(dir, "prepare", "build_date", env).first }
        assert_equal [ "BUILD_DATE=#{date}", "BUILD_DATE=#{date}" ], File.readlines(env_file, chomp: true)
        success, output = resolve(dir, date, ref: "refs/heads/main", extra_env: { "BUILD_DATE" => date })
        assert success
        assert_includes output, "version=#{date}-alpha"
        assert_not_includes output, "compatibility_version=0.7.7"
      end
    end
  end

  test "chart-only release requires an existing image instead of development defaults" do
    with_repo do |dir|
      FileUtils.mkdir_p(File.join(dir, "charts/sure"))
      FileUtils.cp(Rails.root.join("charts/sure/Chart.yaml"), File.join(dir, "charts/sure/Chart.yaml"))
      script = YAML.load_file(Rails.root.join(".github/workflows/chart-release.yml"))
        .fetch("jobs").fetch("prepare_release").fetch("steps").find { |step| step["id"] == "tag" }.fetch("run")
      output_file = File.join(dir, "output")
      env = { "GITHUB_EVENT_NAME" => "push", "GITHUB_REF_NAME" => "chart-v2026.11.2",
        "GITHUB_OUTPUT" => output_file, "APP_VERSION_INPUT" => "" }
      output, status = Open3.capture2e(env, "bash", "-c", script, chdir: dir)
      assert_not status.success?
      assert_includes output, "Select an existing immutable"
      env["APP_VERSION_INPUT"] = "2026.11.1-alpha"
      output, status = Open3.capture2e(env, "bash", "-c", script, chdir: dir)
      assert status.success?, output
      assert_includes File.read(output_file), "app_version=2026.11.1-alpha"
      assert_includes File.read(output_file), "chart_version=2026.11.2"
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
      path = File.join(dir, "output")
      File.write(path, "")
      env = { "COMPATIBILITY_CHANNEL" => workflow.fetch("env").fetch("COMPATIBILITY_CHANNEL"), "COMPATIBILITY_VERSION" => workflow.fetch("env").fetch("COMPATIBILITY_VERSION"),
        "BUILD_DATE" => "2026.10.28", "GITHUB_RUN_NUMBER" => "42",
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
