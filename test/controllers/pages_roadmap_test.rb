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
    assert_select "main section summary", text: /2 items/, count: 3
    assert_select "main section details article", count: 6
    assert_select "h3", text: [
      "Strengthen the foundation",
      "Turn data into insight",
      "The bigger picture"
    ]
    assert_select "h4", text: "Reliable account syncing"
    assert_select "h4", text: "Less financial busywork"
    assert_select "dd", text: "2", count: 2
    assert_select "dd", text: "0", count: 1
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
