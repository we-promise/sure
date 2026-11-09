require "test_helper"
require "open3"
require "tmpdir"
require "yaml"

class ReleaseNotesWorkflowTest < ActiveSupport::TestCase
  test "preserves authored text and changelog around the mobile notice" do
    intro = "# Highlights\n\nKeep `code`, $variables, and [links](https://example.com).  \n\n"
    changes = "## What's Changed\n* Original entry\n\n**Full Changelog**: original\n"
    result = compose(intro + changes)
    assert result.start_with?(intro)
    assert result.end_with?(changes)
    assert_includes result, "credentials.\n\n#{changes}"
    assert_equal result, compose(result)
  end

  test "moves the legacy notice without removing surrounding custom content" do
    mobile = compose("").delete_suffix("\n\n")
    body = "#{mobile}\n\n# Maintainer highlights\n\nCustom mobile advice\n\n## What's Changed\n* Original\n"
    result = compose(body)
    assert result.start_with?("# Maintainer highlights\n\nCustom mobile advice\n\n")
    assert_equal 1, result.scan("## Mobile Debug Builds").size
    assert_equal result, compose(result)
    assert_equal result, compose(body.sub("applications.  Download", "applications. Download"))
  end

  test "appends without dropping text when no changelog heading exists" do
    [ "", "Custom notes without a trailing newline", "Custom\n", "Custom\n\n" ].each do |body|
      result = compose(body)
      assert result.start_with?(body)
      assert_includes result, "## Mobile Debug Builds"
      assert_equal result, compose(result)
    end
  end

  test "supports curly apostrophes and preserves CRLF changelog text" do
    changes = "## What’s Changed\r\n* Keep me\r\n"
    result = compose("Highlights\r\n\r\n#{changes}")
    assert result.start_with?("Highlights\r\n\r\n")
    assert result.end_with?(changes)
    assert_equal result, compose(result)
  end

  test "relocates CRLF notices without changing authored line endings" do
    mobile = compose("").delete_suffix("\n\n").gsub("\n", "\r\n")
    intro = "# Highlights\r\n\r\nKeep this text.  \r\n\r\n"
    changes = "## What's Changed\r\n* Original\r\n"
    [ mobile, mobile.sub("applications.  Download", "applications. Download") ].each do |notice|
      result = compose("#{notice}\r\n\r\n#{intro}#{changes}")
      assert result.start_with?(intro)
      assert result.end_with?(changes)
      assert_equal 1, result.scan("## Mobile Debug Builds").size
      assert_equal result, compose(result)
      assert_equal result, compose(result.gsub(/\r?\n/, "\r\n"))
    end
  end

  test "ignores changelog headings inside backtick and tilde fences" do
    [ "```markdown", "~~~~markdown", "   ````markdown" ].each do |opening|
      fence = opening.strip.delete_suffix("markdown")
      example = "#{opening}\n## What's Changed\n```\n~~~\n## What's Changed\n#{fence}\n\n"
      # A shorter or different-character fence must not end the outer fence.
      example = "#{opening}\n## What's Changed\n#{fence}\n\n" if fence == "```"
      changes = "## What’s Changed\n* Actual change\n"
      result = compose(example + changes)
      assert result.start_with?(example)
      assert result.end_with?(changes)
      assert_includes result, "credentials.\n\n#{changes}"
      assert_equal result, compose(result)
      assert compose(example).start_with?(example)
    end
  end

  test "preserves and deduplicates compatibility aliases" do
    alias_note = "Compatibility alias: v0.7.7 (same commit and image)."
    result = compose("Intro\n\n## What's Changed\n* Change", alias_note: alias_note)
    assert_equal 1, result.scan(alias_note).size
    assert_equal result, compose(result, alias_note: alias_note)
    existing = "#{alias_note}\n\nIntro\n\n## What's Changed\n"
    assert compose(existing, alias_note: alias_note).start_with?("#{alias_note}\n\nIntro\n\n")
  end

  test "generates notes only for missing releases and fails closed on API errors" do
    result = compose(nil, status: 404)
    assert result.end_with?("## What's Changed\n* Generated\n")
    [ 401, 403, 500 ].each do |status|
      assert_nil compose("Do not replace", status: status)
    end
    assert_includes compose(nil), "## Mobile Debug Builds"
  end

  test "publisher uses the prepared body without regenerating or appending notes" do
    release = steps.find { |step| step["name"] == "Create GitHub Release" }.fetch("with")
    assert_equal false, release.fetch("generate_release_notes")
    assert_equal "${{ runner.temp }}/release-notes.md", release.fetch("body_path")
    assert_not release.key?("body")
    assert_not release["append_body"]
  end

  private

    def steps
      YAML.load_file(Rails.root.join(".github/workflows/publish.yml")).fetch("jobs").fetch("release").fetch("steps")
    end

    def compose(body, status: nil, alias_note: "")
      script = steps.find { |step| step["name"] == "Prepare release notes" }.fetch("with").fetch("script")
      Dir.mktmpdir do |dir|
        harness = <<~JS
          const assert = require('node:assert/strict');
          const context = { repo: { owner: 'example', repo: 'sure' } };
          let generated = 0;
          const github = { rest: { repos: {
            getReleaseByTag: async (args) => {
              assert.equal(args.tag, 'v2026.11.4');
              if (#{status.to_json}) throw Object.assign(new Error('API failure'), { status: #{status.to_json} });
              return { data: { body: #{body.to_json} } };
            },
            generateReleaseNotes: async (args) => {
              generated++;
              assert.equal(args.tag_name, 'v2026.11.4');
              return { data: { body: "## What's Changed\\n* Generated\\n" } };
            }
          } } };
          (async () => {
            #{script}
            assert.equal(generated, #{status == 404 ? 1 : 0});
          })().catch(error => { console.error(error); process.exitCode = 1; });
        JS
        output, result = Open3.capture2e({ "RUNNER_TEMP" => dir, "RELEASE_TAG" => "v2026.11.4", "ALIAS_NOTE" => alias_note }, "node", "-e", harness)
        if status && status != 404
          assert_not result.success?
          assert_not File.exist?(File.join(dir, "release-notes.md"))
          return nil
        end
        assert result.success?, output
        File.read(File.join(dir, "release-notes.md"))
      end
    end
end
