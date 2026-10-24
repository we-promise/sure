require "test_helper"

class LocalizedSmallMessagesTest < ActionView::TestCase
  include ApplicationHelper

  test "missing transfer accounts show localized errors while preserving the exact ID" do
    transfer = Struct.new(:id, :from_account, :to_account).new('synthetic-id<&"', nil, nil)
    I18n.with_locale(:"zh-CN") do
      render partial: "transfers/account_links", locals: { transfer: transfer }
      assert_select "span[title]", count: 2, text: "数据错误：缺少账户" do |spans|
        assert spans.all? { |span| span["title"] == '转账 ID：synthetic-id<&"' }
      end
      assert_select "img, script", count: 0
    end
  end

  test "invite removal retains its existing action and uses the localized confirmation" do
    invite = InviteCode.new(id: "00000000-0000-4000-8000-000000000001", token: "SYNTHETIC-ONLY")
    I18n.with_locale(:"zh-CN") do
      render partial: "invite_codes/invite_code", locals: { invite_code: invite }
      assert_select "form[action=?]", invite_code_path(invite)
      assert_select "[data-confirm=?]", I18n.t("layouts.shared.confirm_dialog.are_you_sure")
      assert_select "input[name='_method'][value='delete']"
      assert_select "[data-clipboard-target='source']", text: "SYNTHETIC-ONLY"
    end
  end
end
