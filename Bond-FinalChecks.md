## TODO: Code Review Fixes (CodeRabbit)

---

### 🔴 BLOCKER

- [x] **Periodic coupon dla inflation_linked (us_tips_10y)**  
  `coupon_amount_per_period` nie obsługuje zmiennego oprocentowania (CPI + margin).  
  Dla `inflation_linked` z `coupon_frequency != at_maturity` zwraca `nil`.  
  Decyzja: czy implementujemy dynamiczne kupon dla TIPS, czy na razie pomijamy?

---

### 🟠 WARNING

- [x] **Kosztowne wywołania w callbacku `clear_rate_review_flag`**  
  `rates_resolvable_through?` → `annual_rate_for` → lookup CPI/provider  
  Wykonuje się przy `save/update` w requestach webowych.  
  Plan: dodać tryb `allow_import: false` w ścieżce walidacji, żeby nie odpalać importów/live fetch.

- [x] **Dodać test: walidacja nie robi live importu CPI**  
  Dla `requires_rate_review` + provider non-GUS walidacja ma używać tylko danych lokalnych/persisted.

- [ ] **Dashboard summary — ryzyko N+1 / koszt obliczeniowy**  
  Dla każdego lotu: `estimated_current_value` (iteracja po okresach + rate lookup)  
  Brak cache dla rate context per data/provider.  
  Rozważ: memoizacja, cache, lub batch loading.

- [ ] **Controller zbyt gruby (skinny controllers!)**  
  Tworzenie/aktualizacja lotu + entry + sync + mapowanie błędów  
  Przenieść do modelu lub command object (PORO).

- [x] **Brak testu bezpieczeństwa — tax wrapper**  
  Brak potwierdzenia że `tax_strategy/tax_rate` z requestu nie nadpisują polityki modelu.  
  Dodać test: przy `tax_exempt` wrapper parametry tax nie powinny być akceptowane.

- [x] **Dodać test controllera dla tax wrapper (IKE/IKZE)**  
  `bond_lots_controller_test`: przy `tax_wrapper=ike` przekazane `tax_strategy/tax_rate` mają zostać znormalizowane do `exempt/0`.

---

### 🟡 INFO

- [ ] **Autoryzacja OK**  
  `family + accessible_by + require_account_permission!` — wszystko git.  
  *(Niczego nie robić)*

- [ ] **SQL injection — OK**  
  Brak dynamicznego SQL z user input.  
  *(Niczego nie robić)*

---

### ❓ Otwarte pytania

1. **TIPS coupon** — ma być liczony dynamicznie z CPI + margin, czy świadomie pomijany na tym etapie?
2. **Network calls w walidacji** — czy akceptujemy wywołania zewnętrznych API w model callback, czy przenosimy do background (np. Sidekiq job)?
