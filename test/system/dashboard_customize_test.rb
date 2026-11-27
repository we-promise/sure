require "application_system_test_case"

class DashboardCustomizeTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
  end

  test "hides a widget from the keyboard and adds it back" do
    sign_in @user
    net_worth = I18n.t("pages.dashboard.net_worth_chart.title")

    click_on I18n.t("pages.dashboard.customize.start"), match: :first
    find_button(I18n.t("pages.dashboard.customize.hide", title: net_worth)).send_keys(:enter)

    assert_no_selector "section[data-section-key='net_worth_chart']"
    assert_equal net_worth, page.evaluate_script("document.activeElement.textContent").strip

    click_on net_worth
    assert_selector "section[data-section-key='net_worth_chart']"
    assert_equal "net_worth_chart", page.evaluate_script("document.activeElement.dataset.sectionKey")

    click_on I18n.t("pages.dashboard.customize.done")
    assert_no_button I18n.t("pages.dashboard.customize.hide", title: net_worth)
  end

  test "a widget moved with the keyboard keeps its new place" do
    sign_in @user
    first, second = all("section[data-section-key]").first(2).map { |section| section["data-section-key"] }
    record_saved_section_order

    find("section[data-section-key='#{first}']").send_keys(:enter)
    page.send_keys(:arrow_down)
    page.send_keys(:enter)

    assert_selector "html[data-order-saved='200']"
    saved_order = @user.reload.dashboard_section_order
    assert_operator saved_order.index(second), :<, saved_order.index(first)
  end

  test "a widget dropped on the lower half of the last widget moves to the end" do
    sign_in @user
    keys = all("section[data-section-key]").map { |section| section["data-section-key"] }
    record_saved_section_order

    page.execute_script(<<~JS, keys.first, keys.last)
      const [draggedKey, targetKey] = arguments;
      const dragged = document.querySelector(`section[data-section-key='${draggedKey}']`);
      const target = document.querySelector(`section[data-section-key='${targetKey}']`);
      const box = target.getBoundingClientRect();
      const point = { clientX: box.left + box.width / 2, clientY: box.bottom - 5 };
      const dataTransfer = new DataTransfer();
      dragged.dispatchEvent(new DragEvent("dragstart", { bubbles: true, dataTransfer }));
      target.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer, ...point }));
      target.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer, ...point }));
      dragged.dispatchEvent(new DragEvent("dragend", { bubbles: true, dataTransfer }));
    JS

    assert_selector "html[data-order-saved='200']"
    assert_equal keys.drop(1) + [ keys.first ], @user.reload.dashboard_section_order.select { |key| keys.include?(key) }
  end

  test "a drop that did not start on a widget changes nothing" do
    sign_in @user
    keys = all("section[data-section-key]").map { |section| section["data-section-key"] }
    record_saved_section_order

    # One finished widget drag, then a file or text dragged in from outside.
    page.execute_script(<<~JS, keys.first, keys.last)
      const [draggedKey, targetKey] = arguments;
      const dragged = document.querySelector(`section[data-section-key='${draggedKey}']`);
      const target = document.querySelector(`section[data-section-key='${targetKey}']`);
      const box = target.getBoundingClientRect();
      const point = { clientX: box.left + box.width / 2, clientY: box.top + 5 };
      const drag = (element, type, init = {}) =>
        element.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: new DataTransfer(), ...init }));
      drag(dragged, "dragstart");
      drag(dragged, "dragend");
      drag(target, "dragover", point);
      drag(target, "drop", point);
    JS

    assert_equal keys, all("section[data-section-key]").map { |section| section["data-section-key"] }
    assert_no_text "null"
    assert_nil page.evaluate_script("document.documentElement.dataset.orderRequests")
  end
end
