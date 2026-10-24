require "test_helper"

class AccountNoticeLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.family.update!(auto_sync_on_login: false)
    sign_in @user
    Account.any_instance.stubs(:sync_later)
  end

  {
    "en" => [ "Other Asset", "Other asset account created", "Other asset account updated" ],
    "de" => [ "Sonstiges Vermögen", "Sonstiges Vermögen-Konto erstellt", "Sonstiges Vermögen-Konto aktualisiert" ],
    "tr" => [ "Diğer Varlık", "Diğer Varlık hesabı oluşturuldu", "Diğer Varlık hesabı güncellendi" ],
    "zh-CN" => [ "其他资产", "已创建 其他资产 账户", "已更新 其他资产 账户" ]
  }.each do |locale, (display_label, created_notice, updated_notice)|
    test "#{locale} account notices preserve sentence casing and global display labels" do
      post other_assets_path(locale: locale), params: {
        account: { name: "Synthetic original NAME", balance: 0, currency: "USD", accountable_type: "OtherAsset" }
      }

      assert_response :redirect
      assert_equal created_notice, flash[:notice]
      account = @user.family.accounts.find_by!(name: "Synthetic original NAME")
      assert_equal display_label, I18n.with_locale(locale) { OtherAsset.singular_display_name }

      patch other_asset_path(account, locale: locale), params: { account: { name: "Synthetic updated NAME" } }

      assert_response :redirect
      assert_equal updated_notice, flash[:notice]
      assert_equal "Synthetic updated NAME", account.reload.name
      assert_equal display_label, I18n.with_locale(locale) { OtherAsset.singular_display_name }
    end
  end
end
