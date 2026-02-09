#!/bin/bash
cd /home/daniel/sure
git add app/controllers/transactions_controller.rb app/controllers/transactions/bulk_updates_controller.rb
git commit -m "fix: add error handling for ApplyRulesToTransactionService calls"
git push origin fix/wise-enablebanking-counterparty-priority

