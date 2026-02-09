#!/bin/bash
export GIT_PAGER=cat
export PAGER=cat
cd /home/daniel/sure
git remote set-url origin https://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@github.com/Angel98518/sure.git
git add app/controllers/transactions/bulk_updates_controller.rb
git commit -m "Merge upstream/main: resolve conflict in bulk_updates_controller"
git push origin fix/wise-enablebanking-counterparty-priority 2>&1

