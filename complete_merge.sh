#!/bin/bash
cd /home/daniel/sure
git add app/controllers/transactions/bulk_updates_controller.rb
git commit -m "Merge upstream/main: resolve conflict in bulk_updates_controller

- Resolved conflict by combining both changes:
  - Keep entry_ids variable for rules application
  - Add update_tags parameter from upstream/main"
git push origin fix/wise-enablebanking-counterparty-priority

