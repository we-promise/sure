require "test_helper"

class Brazil::BankCatalogImporterTest < ActiveSupport::TestCase
  SAMPLE_CATALOG = <<~CSV
    ISPB;Nome_Reduzido;Numero_Codigo;Participa_da_Compe;Acesso;Nome_Extenso;Inicio_Operacao
    18236120;NU PAGAMENTOS;260;Sim;RSFN;NU PAGAMENTOS S.A. - INSTITUICAO DE PAGAMENTO;2017-10-30
    60701190;ITAU UNIBANCO;341;Sim;RSFN;ITAU UNIBANCO S.A.;1943-12-30
    00000000;BCB;n/a;Nao;RSFN;BANCO CENTRAL DO BRASIL;1964-12-31
  CSV

  setup do
    Brazil::Bank.delete_all
  end

  test "imports catalog rows idempotently by ispb" do
    imported = Brazil::BankCatalogImporter.new(
      text: SAMPLE_CATALOG,
      source_updated_on: Date.new(2026, 5, 1)
    ).call

    assert_equal 3, imported
    assert_equal 3, Brazil::Bank.count

    imported_again = Brazil::BankCatalogImporter.new(
      text: SAMPLE_CATALOG.sub("NU PAGAMENTOS", "NUBANK"),
      source_updated_on: Date.new(2026, 5, 1)
    ).call

    assert_equal 3, imported_again
    assert_equal 3, Brazil::Bank.count
    assert_equal "Nubank", Brazil::Bank.find_by!(ispb: "18236120").short_name
  end

  test "marks infrastructure rows as hidden from account selection" do
    Brazil::BankCatalogImporter.new(text: SAMPLE_CATALOG).call

    assert Brazil::Bank.find_by!(code: "260").display_in_account_selector?
    assert_not Brazil::Bank.find_by!(ispb: "00000000").display_in_account_selector?
  end

  test "assigns curated logo keys for known banks" do
    Brazil::BankCatalogImporter.new(text: SAMPLE_CATALOG).call

    assert_equal "nubank", Brazil::Bank.find_by!(code: "260").logo_key
    assert_equal "itau", Brazil::Bank.find_by!(code: "341").logo_key
  end
end
