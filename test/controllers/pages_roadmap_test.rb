require "test_helper"

class PagesRoadmapTest < ActionDispatch::IntegrationTest
  test "roadmap is public and renders collapsed roadmap phases" do
    get roadmap_path

    assert_response :ok
    assert_select "h1", text: "The Sure roadmap"
    assert_select "aside[aria-labelledby='roadmap-status-heading']"
    assert_select "main section details", count: 3
    assert_select "main section details:not([open])", count: 3
    assert_select "main section summary", count: 3
    assert_select "main section summary", text: /6 items/, count: 2
    assert_select "main section summary", text: /5 items/, count: 1
    assert_select "main section details article", count: 17
    assert_select "h3", text: [
      "Stabilize and polish the core",
      "Expand personal-finance capability",
      "Open the platform carefully"
    ]
    assert_select "h4", text: "Reliability, performance, and technical-debt reduction"
    assert_select "h4", text: "Business finance support"
    assert_select "dd", text: "5", count: 1
    assert_select "dd", text: "7", count: 1
    assert_select "dd", text: "5", count: 1
  end

  test "renders an accessible GitHub issue link when the Markdown item has one" do
    item = RoadmapMarkdown::Item.new("Linked item", "Item description.", :planned, "https://github.com/we-promise/sure/issues/42")
    phase = RoadmapMarkdown::Phase.new("Linked phase", "Phase description.", [ item ])

    RoadmapMarkdown.stubs(:load).returns([ phase ])
    get roadmap_path

    assert_response :ok
    assert_select "a[href='https://github.com/we-promise/sure/issues/42'][aria-label='View GitHub issue for Linked item']", text: "GitHub issue for Linked item"
  end
end
