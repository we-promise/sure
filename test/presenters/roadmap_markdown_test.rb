require "test_helper"

class RoadmapMarkdownTest < ActiveSupport::TestCase
  test "parses phases and items in document order with statuses and issue links" do
    markdown = <<~MARKDOWN
      <!-- roadmap:v1 -->
      ## Phase: First phase
      Description: First phase description.
      ### Item: First item
      Status: in_progress
      Description: First item description.
      Issue: [#42](https://github.com/we-promise/sure/issues/42)
      ### Item: Second item
      Status: planned
      Description: Second item description.
      ## Phase: Second phase
      Description: Second phase description.
      ### Item: Third item
      Status: exploring
      Description: Third item description.
    MARKDOWN

    phases = RoadmapMarkdown.new(markdown, logger: nil).parse

    assert_equal [ "First phase", "Second phase" ], phases.map(&:name)
    assert_equal [ "First item", "Second item" ], phases.first.items.map(&:title)
    assert_equal [ :in_progress, :planned ], phases.first.items.map(&:status)
    assert_equal "https://github.com/we-promise/sure/issues/42", phases.first.items.first.issue_url
  end

  test "skips malformed metadata and rejects non-GitHub issue links" do
    markdown = <<~MARKDOWN
      <!-- roadmap:v1 -->
      ## Phase: Safe phase
      Description: Safe description.
      ### Item: Missing status
      Description: Omitted.
      ### Item: Unsafe link
      Status: planned
      Description: Kept without its link.
      Issue: [bad](http://example.com/item)
    MARKDOWN

    items = RoadmapMarkdown.new(markdown, logger: nil).parse.flat_map(&:items)

    assert_equal [ "Unsafe link" ], items.map(&:title)
    assert_nil items.first.issue_url
  end

  test "returns no phases when the format marker is missing" do
    assert_empty RoadmapMarkdown.new("## Phase: Not a roadmap", logger: nil).parse
  end
end
