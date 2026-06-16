require "test_helper"

class Brazil::BankTest < ActiveSupport::TestCase
  setup do
    Brazil::Bank.delete_all
  end

  test "displayable hides infrastructure rows and rows without a usable bank code" do
    nubank = Brazil::Bank.create!(
      ispb: "18236120",
      code: "260",
      name: "NU PAGAMENTOS S.A. - INSTITUICAO DE PAGAMENTO",
      short_name: "Nu Pagamentos",
      display_in_account_selector: true
    )

    Brazil::Bank.create!(
      ispb: "00000000",
      code: nil,
      name: "BANCO CENTRAL DO BRASIL",
      short_name: "BCB",
      display_in_account_selector: false
    )

    Brazil::Bank.create!(
      ispb: "00394460",
      code: "n/a",
      name: "SECRETARIA DO TESOURO NACIONAL",
      short_name: "STN",
      display_in_account_selector: false
    )

    assert_equal [ nubank ], Brazil::Bank.displayable.to_a
  end

  test "search matches code ispb short name and full name" do
    nubank = Brazil::Bank.create!(
      ispb: "18236120",
      code: "260",
      name: "NU PAGAMENTOS S.A. - INSTITUICAO DE PAGAMENTO",
      short_name: "Nu Pagamentos",
      display_in_account_selector: true
    )

    Brazil::Bank.create!(
      ispb: "60701190",
      code: "341",
      name: "ITAU UNIBANCO S.A.",
      short_name: "Itau",
      display_in_account_selector: true
    )

    assert_equal [ nubank ], Brazil::Bank.search("260").to_a
    assert_equal [ nubank ], Brazil::Bank.search("18236120").to_a
    assert_equal [ nubank ], Brazil::Bank.search("pagamentos").to_a
    assert_equal [ nubank ], Brazil::Bank.search("instituicao").to_a
  end

  test "selector label includes name code and ispb for disambiguation" do
    bank = Brazil::Bank.new(
      ispb: "00000208",
      code: "001",
      name: "BANCO DO BRASIL S.A.",
      short_name: "Banco do Brasil"
    )

    assert_equal "Banco do Brasil - 001 - ISPB 00000208", bank.selector_label
  end
end
