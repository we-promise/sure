require "test_helper"
require "open3"
require "tmpdir"

class ReleaseVersionTest < ActiveSupport::TestCase
  test "canonical release emits one stable image and its legacy alias" do
    release = ReleaseVersion.new("2026.10.31", aliases: { "2026.10.31" => "0.7.6" })
    assert_equal %w[2026.10.31 0.7.6 stable], release.image_versions
    assert release.publish_tag?("refs/tags/v2026.10.31")
    assert_not release.publish_tag?("refs/tags/v0.7.6")
    assert_raises(ArgumentError) { release.publish_tag?("refs/tags/v0.7.7") }
  end

  test "alpha with or without cycle count updates latest but never stable" do
    %w[2026.11.2-alpha 2026.11.2-alpha.12].each do |version|
      release = ReleaseVersion.new(version)
      assert_equal [ version, "latest" ], release.image_versions
      assert_not release.stable?
    end
  end

  test "beta and rc are immutable versions without floating channel promotion" do
    %w[2026.10.31-beta 2026.10.31-rc.2].each do |version|
      assert_equal [ version ], ReleaseVersion.new(version).image_versions
    end
  end

  test "calendar validation rejects padding invalid dates and hotfix modifiers" do
    %w[2026.11.02 2026.0.1 2026.11.0 2026.2.29 2026.4.31 2026.10.31-hotfix.1 2026.10.31-1].each do |version|
      assert_raises(ArgumentError, version) { ReleaseVersion.new(version) }
    end
    assert ReleaseVersion.new("2028.2.29").stable?
  end

  test "aliases expire after 2026 and do not leak to other dates or prereleases" do
    aliases = { "2026.10.31" => "0.7.6" }
    assert_equal %w[2026.11.1 stable], ReleaseVersion.new("2026.11.1", aliases: aliases).image_versions
    assert_equal %w[2026.10.31-alpha latest], ReleaseVersion.new("2026.10.31-alpha", aliases: aliases).image_versions
    assert_equal %w[2027.1.1 stable], ReleaseVersion.new("2027.1.1", aliases: aliases).image_versions
    assert_raises(ArgumentError) { ReleaseVersion.new("2027.1.1", aliases: { "2027.1.1" => "0.7.9" }) }
    assert_raises(ArgumentError) { ReleaseVersion.new("2026.10.31-alpha", aliases: { "2026.10.31-alpha" => "0.7.6" }) }
  end

  test "CalVer remains sortable by the application across migration and year rollover" do
    %w[0.7.6 2026.10.31 2026.11.1-alpha 2026.11.1 2027.1.1].each_cons(2) do |older, newer|
      assert Semver.new(newer) > Semver.new(older)
    end
  end

  test "compatibility tag creation is idempotent and rejects a different commit" do
    Dir.mktmpdir do |dir|
      remote = File.join(dir, "remote.git")
      repo = File.join(dir, "repo")
      git!(dir, "init", "--bare", remote)
      git!(dir, "init", repo)
      git!(repo, "config", "user.email", "test@example.com")
      git!(repo, "config", "user.name", "Release Test")
      git!(repo, "remote", "add", "origin", remote)
      git!(repo, "commit", "--allow-empty", "-m", "canonical")
      canonical = git!(repo, "rev-parse", "HEAD").strip
      2.times do
        output, status = Open3.capture2e(Rails.root.join("bin/release-alias").to_s, "0.7.6", chdir: repo)
        assert status.success?, output
      end
      assert_equal canonical, git!(remote, "rev-parse", "v0.7.6").strip
      git!(repo, "tag", "-a", "v0.7.7", "-m", "annotated alias")
      git!(repo, "push", "origin", "v0.7.7")
      output, status = Open3.capture2e(Rails.root.join("bin/release-alias").to_s, "0.7.7", chdir: repo)
      assert status.success?, output
      git!(repo, "commit", "--allow-empty", "-m", "different")
      output, status = Open3.capture2e(Rails.root.join("bin/release-alias").to_s, "0.7.6", chdir: repo)
      assert_not status.success?
      assert_includes output, "refusing to move"
      assert_equal canonical, git!(remote, "rev-parse", "v0.7.6").strip
    end
  end

  test "metadata gates aliases and requires stable release branch membership" do
    with_metadata_repo do |dir|
      output, status, values = metadata(dir, "push", "refs/tags/v2026.10.31")
      assert_not status.success?, output
      assert_includes output, "must be on v0.7.6-release-branch"
      git!(dir, "update-ref", "refs/remotes/origin/v0.7.6-release-branch", "HEAD")
      output, status, values = metadata(dir, "push", "refs/tags/v2026.10.31")
      assert status.success?, output
      assert_includes values, "release=true"
      assert_includes values, "type=raw,value=0.7.6"
      assert_includes values, "type=raw,value=stable"
      output, status, values = metadata(dir, "push", "refs/tags/v0.7.6")
      assert status.success?, output
      assert_includes values, "publish=false"
      assert_includes values, "release=false"
      assert_not_includes values, "type=raw"
      output, status, = metadata(dir, "push", "refs/tags/v2026.11.1")
      assert_not status.success?, output
    end
  end

  test "branch schedule and manual builds do not publish release channels" do
    with_metadata_repo do |dir|
      [ [ "push", "refs/heads/main" ], [ "schedule", "refs/heads/main" ],
        [ "workflow_dispatch", "refs/tags/v2026.10.31" ] ].each do |event, ref|
        output, status, values = metadata(dir, event, ref)
        assert status.success?, output
        assert_includes values, "release=false"
        assert_includes values, "publish=true"
        assert_not_includes values, "type=raw"
        assert_includes values, "type=schedule,pattern=nightly" if event == "schedule"
      end
    end
  end

  test "alpha metadata supports unnumbered modifiers without stable branch" do
    with_metadata_repo do |dir|
      File.write(File.join(dir, ".sure-version"), "2026.11.2-alpha\n")
      output, status, values = metadata(dir, "push", "refs/tags/v2026.11.2-alpha")
      assert status.success?, output
      assert_includes values, "alpha=true"
      assert_includes values, "stable=false"
      assert_includes values, "type=raw,value=latest"
      assert_not_includes values, "type=raw,value=stable"
      assert_not_includes values, "type=raw,value=0.7.6"
    end
  end

  private
    def with_metadata_repo
      Dir.mktmpdir do |dir|
        %w[bin lib config].each { |name| FileUtils.mkdir_p(File.join(dir, name)) }
        %w[bin/release-metadata lib/release_version.rb].each do |path|
          FileUtils.cp(Rails.root.join(path), File.join(dir, path))
        end
        File.write(File.join(dir, ".sure-version"), "2026.10.31\n")
        File.write(File.join(dir, ".sure-release-branch"), "v0.7.6-release-branch\n")
        File.write(File.join(dir, "config/release_aliases.json"), { "2026.10.31" => "0.7.6" }.to_json)
        git!(dir, "init")
        git!(dir, "config", "user.email", "test@example.com")
        git!(dir, "config", "user.name", "Release Test")
        git!(dir, "commit", "--allow-empty", "-m", "candidate")
        yield dir
      end
    end

    def metadata(dir, event, ref)
      path = File.join(dir, "output")
      File.write(path, "")
      env = { "GITHUB_EVENT_NAME" => event, "GITHUB_REF" => ref, "GITHUB_OUTPUT" => path }
      output, status = Open3.capture2e(env, RbConfig.ruby, File.join(dir, "bin/release-metadata"), chdir: dir)
      [ output, status, File.read(path) ]
    end

    def git!(directory, *args)
      output, status = Open3.capture2e("git", *args, chdir: directory)
      assert status.success?, output
      output
    end
end
