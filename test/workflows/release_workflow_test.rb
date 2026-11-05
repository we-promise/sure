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
      %w[release=true compatibility_version=0.7.7-alpha.3 type=raw,value=2026.10.30-alpha type=raw,value=0.7.7-alpha.3].each { |line| assert_includes output, line }
      success, output = resolve(dir, "2026.10.28", ref: "refs/tags/v0.7.7-alpha.3")
      assert success
      assert_includes output, "publish=false"
      assert_includes output, "release=false"
      assert_not resolve(dir, "2026.10.28", ref: "refs/tags/vgarbage").first
    end
  end

  test "alpha and stable releases publish only their matching floating channel" do
    with_repo do |dir|
      %w[2026.11.2-alpha 2026.11.2].each do |version|
        success, output = resolve(dir, version)
        assert success, version
        assert_includes output, "release=true"
        assert_includes output, "type=raw,value=#{version}"
        channel, other_channel = version.end_with?("-alpha") ? %w[latest stable] : %w[stable latest]
        assert_includes output, "type=raw,value=#{channel}"
        assert_not_includes output, "type=raw,value=#{other_channel}"
      end
    end
  end

  test "Docker metadata disables automatic latest tagging" do
    metadata = workflow.fetch("jobs").fetch("build").fetch("steps").find { |step| step["id"] == "meta" }.fetch("with")
    assert_equal "latest=false", metadata.fetch("flavor")
    assert_equal "${{ needs.prepare.outputs.image_tags }}", metadata.fetch("tags")
  end

  test "compatibility channel follows release dates without matching other channels" do
    with_repo do |dir|
      %w[alpha stable].each do |phase|
        suffix = phase == "stable" ? "" : "-#{phase}"
        version = "2026.11.2#{suffix}"
        legacy = phase == "stable" ? "0.7.7" : "0.7.7-alpha.4"
        success, output = resolve(dir, version, extra_env: { "COMPATIBILITY_CHANNEL" => phase, "COMPATIBILITY_VERSION" => legacy })
        assert success
        assert_includes output, "compatibility_version=#{legacy}"
      end
      %w[2026.10.31-alpha 2026.11.2-alpha 2026.12.31-alpha].each do |version|
        success, output = resolve(dir, version, extra_env: { "BUILD_DATE" => "2027.1.2" })
        assert success
        assert_includes output, "version=#{version}"
        assert_includes output, "compatibility_version=0.7.7-alpha.3"
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
      %w[2026.11.02 2026.11.0 2026.2.29 2026.4.31 2026.10.28-hotfix.1 2026.10.28-1 2026.10.30-alpha.2 2026.10.30-alpha.0 2026.10.30-beta 2026.10.30-rc.1 2026.10.30-daily 2026.10.30-nightly].each do |version|
        assert_not resolve(dir, version).first, version
      end
    end
  end

  test "non-release builds and January do not emit compatibility tags" do
    with_repo do |dir|
      # Fork: push ke main MEMANG mengeluarkan tag stable/latest (produksi
      # fork men-deploy :stable di setiap push main). Yang tetap dilarang
      # adalah schedule dan build manual (workflow_dispatch) yang
      # mengeluarkan tag floating.
      [ "schedule", "workflow_dispatch" ].each do |event|
        success, output = resolve(dir, "2026.10.28", event: event, ref: "refs/heads/main")
        assert success
        assert_includes output, "release=false"
        expected_version = event == "schedule" ? "2026.10.28-nightly" : "2026.10.28-alpha"
        assert_includes output, "version=#{expected_version}\n"
        assert_not_includes output, "type=raw,value=latest"
        assert_not_includes output, "type=raw,value=stable"
        assert_not_includes output, "compatibility_version=0.7.7"
        if event == "schedule"
          assert_includes output, "type=schedule,pattern=nightly"
          assert_includes output, "type=raw,value=2026.10.28-nightly"
          assert_not_includes output, "pattern=nightly-"
        else
          assert_includes output, "type=raw,value=sha-#{git!(dir, 'rev-parse', 'HEAD').strip}"
        end
      end
      success, output = resolve(dir, "2026.10.28", event: "push", ref: "refs/heads/main")
      assert success
      assert_includes output, "release=false"
      assert_includes output, "version=2026.10.28-alpha\n"
      assert_includes output, "type=raw,value=sha-#{git!(dir, 'rev-parse', 'HEAD').strip}"
      assert_includes output, "type=raw,value=stable"
      assert_includes output, "type=raw,value=latest"
      assert_not_includes output, "compatibility_version=0.7.7"
      success, output = resolve(dir, "2027.1.1", extra_env: { "COMPATIBILITY_CHANNEL" => "stable" })
      assert success
      assert_not_includes output, "type=raw,value=0.7.7"
      assert_includes output, "type=raw,value=2027.1.1"
      assert_includes output, "type=raw,value=stable"
      assert_not_includes output, "type=raw,value=latest"
    end
  end

  test "manual tag builds preserve selected identity without publishing a release" do
    with_repo do |dir|
      workflow_sha = git!(dir, "rev-parse", "HEAD").strip
      git!(dir, "commit", "--allow-empty", "-m", "selected commit")
      selected_sha = git!(dir, "rev-parse", "HEAD").strip
      %w[2026.11.2 2026.11.2-alpha].each do |version|
        git!(dir, "tag", "-a", "v#{version}", "-m", "release")
        [ "v#{version}", "refs/tags/v#{version}" ].each do |selected_ref|
          success, output = resolve(dir, version, event: "workflow_dispatch", ref: "refs/heads/main",
            extra_env: { "SELECTED_REF" => selected_ref, "GITHUB_SHA" => workflow_sha })
          assert success, output
          assert_includes output, "version=#{version}\n"
          assert_includes output, "release=false"
          assert_includes output, "compatibility_version=\n"
          assert_includes output, "type=raw,value=sha-#{selected_sha}"
          assert_not_includes output, "type=raw,value=sha-#{workflow_sha}"
          assert_not_includes output, "type=raw,value=#{version}"
          assert_not_includes output, "type=raw,value=stable"
          assert_not_includes output, "type=raw,value=latest"
        end
      end
      [ "main", "refs/heads/main", selected_sha ].each do |selected_ref|
        success, output = resolve(dir, "unused", event: "workflow_dispatch", ref: "refs/tags/v2026.11.2",
          extra_env: { "SELECTED_REF" => selected_ref })
        assert success, output
        assert_includes output, "version=2026.10.28-alpha"
        assert_includes output, "release=false"
      end
      %w[v2026.11.31 v2026.11.2-beta v0.7.7].each do |tag|
        git!(dir, "tag", tag)
        assert_not resolve(dir, "unused", event: "workflow_dispatch", ref: "refs/heads/main",
          extra_env: { "SELECTED_REF" => tag }).first
      end
    end
  end

  test "nightly identity is shared by the dated tag embedded version and OCI metadata" do
    with_repo do |dir|
      success, output = resolve(dir, "unused", event: "schedule", ref: "refs/heads/main",
        extra_env: { "BUILD_DATE" => "2026.11.3" })
      assert success, output
      version = output.lines.find { |line| line.start_with?("version=") }.strip.delete_prefix("version=")
      assert_equal "2026.11.3-nightly", version
      assert_includes output, "type=raw,value=#{version}\n"
      assert_includes output, "compatibility_version=\n"
      assert run_step(dir, "build", "version_file", "VERSION" => version).first
      assert_equal "#{version}\n", File.read(File.join(dir, ".sure-version"))

      build_steps = workflow.fetch("jobs").fetch("build").fetch("steps")
      version_step = build_steps.find { |step| step["id"] == "version_file" }
      metadata = build_steps.find { |step| step["id"] == "meta" }.fetch("with")
      assert_equal "${{ needs.prepare.outputs.version }}", version_step.fetch("env").fetch("VERSION")
      assert_includes metadata.fetch("labels"), "org.opencontainers.image.version=${{ needs.prepare.outputs.version }}"

      merge_step = workflow.fetch("jobs").fetch("merge").fetch("steps").find { |step| step["name"] == "Merge and push Docker image" }
      assert_equal "${{ needs.prepare.outputs.version }}", merge_step.fetch("env").fetch("VERSION")
      assert_includes merge_step.fetch("run"), "--annotation=index:org.opencontainers.image.version=$VERSION"
    end
  end

  test "non-force alias step accepts retries and annotated tags but not other commits" do
    with_repo do |dir|
      remote = File.join(dir, "remote.git")
      git!(dir, "init", "--bare", remote)
      git!(dir, "remote", "add", "origin", remote)
      2.times { assert run_step(dir, "merge", "compatibility", "COMPATIBILITY_VERSION" => "0.7.7-alpha.3").first }
      git!(dir, "tag", "-a", "v0.7.7", "-m", "annotated")
      git!(dir, "push", "origin", "v0.7.7")
      assert run_step(dir, "merge", "compatibility", "COMPATIBILITY_VERSION" => "0.7.7").first
      original = git!(remote, "rev-parse", "v0.7.7-alpha.3")
      git!(dir, "commit", "--allow-empty", "-m", "different")
      success, output = run_step(dir, "merge", "compatibility", "COMPATIBILITY_VERSION" => "0.7.7-alpha.3")
      assert_not success
      assert_includes output, "refusing to move"
      assert_equal original, git!(remote, "rev-parse", "v0.7.7-alpha.3")
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
        2.times do
          success, output = resolve(dir, date, event: "schedule", ref: "refs/heads/main", extra_env: { "BUILD_DATE" => date })
          assert success
          assert_includes output, "version=#{date}-nightly\n"
          assert_includes output, "release=false\n"
          assert_includes output, "stable=false\n"
          assert_includes output, "alpha=false\n"
          assert_includes output, "type=raw,value=#{date}-nightly"
          assert_includes output, "type=raw,value=sha-#{git!(dir, 'rev-parse', 'HEAD').strip}"
          assert_includes output, "type=schedule,pattern=nightly"
          assert_not_includes output, "pattern=nightly-"
        end
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
      env = { "COMPATIBILITY_CHANNEL" => "alpha", "COMPATIBILITY_VERSION" => "0.7.7-alpha.3",
        "BUILD_DATE" => "2026.10.28", "GITHUB_RUN_NUMBER" => "42",
        "GITHUB_EVENT_NAME" => event,
        "SELECTED_REF" => ref, "GITHUB_REF" => ref, "GITHUB_OUTPUT" => path }.merge(extra_env)
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
