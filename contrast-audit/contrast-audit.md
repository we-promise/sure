# DS contrast audit — static token-pair pass

Computed via `tmp/contrast-audit.mjs`. WCAG 2.1 ratios. AA for normal text = 4.5:1; AA for large text or non-text/UI = 3:1; AAA for normal text = 7:1.

## Light mode

| Foreground | Background | Foreground hex | Background hex | Ratio | Verdict |
|---|---|---|---|---|---|
| ✓ `text-primary` | `bg-container` | `#171717` | `#FFFFFF` | 17.93 | AAA |
| ✓ `text-secondary` | `bg-container` | `#737373` | `#FFFFFF` | 4.74 | AA |
| ❌ `text-subdued` | `bg-container` | `#9E9E9E` | `#FFFFFF` | 2.68 | FAIL |
| ✓ `text-link` | `bg-container` | `#1570EF` | `#FFFFFF` | 4.57 | AA |
| ✓ `text-primary` | `bg-container-hover` | `#171717` | `#F7F7F7` | 16.73 | AAA |
| ⚠️ `text-secondary` | `bg-container-hover` | `#737373` | `#F7F7F7` | 4.43 | AA-large only |
| ❌ `text-subdued` | `bg-container-hover` | `#9E9E9E` | `#F7F7F7` | 2.50 | FAIL |
| ⚠️ `text-link` | `bg-container-hover` | `#1570EF` | `#F7F7F7` | 4.27 | AA-large only |
| ✓ `text-primary` | `bg-container-inset` | `#171717` | `#F7F7F7` | 16.73 | AAA |
| ⚠️ `text-secondary` | `bg-container-inset` | `#737373` | `#F7F7F7` | 4.43 | AA-large only |
| ❌ `text-subdued` | `bg-container-inset` | `#9E9E9E` | `#F7F7F7` | 2.50 | FAIL |
| ⚠️ `text-link` | `bg-container-inset` | `#1570EF` | `#F7F7F7` | 4.27 | AA-large only |
| ✓ `text-primary` | `bg-container-inset-hover` | `#171717` | `#F0F0F0` | 15.73 | AAA |
| ⚠️ `text-secondary` | `bg-container-inset-hover` | `#737373` | `#F0F0F0` | 4.16 | AA-large only |
| ❌ `text-subdued` | `bg-container-inset-hover` | `#9E9E9E` | `#F0F0F0` | 2.35 | FAIL |
| ⚠️ `text-link` | `bg-container-inset-hover` | `#1570EF` | `#F0F0F0` | 4.01 | AA-large only |
| ✓ `text-primary` | `bg-surface` | `#171717` | `#F7F7F7` | 16.73 | AAA |
| ⚠️ `text-secondary` | `bg-surface` | `#737373` | `#F7F7F7` | 4.43 | AA-large only |
| ❌ `text-subdued` | `bg-surface` | `#9E9E9E` | `#F7F7F7` | 2.50 | FAIL |
| ⚠️ `text-link` | `bg-surface` | `#1570EF` | `#F7F7F7` | 4.27 | AA-large only |
| ✓ `text-primary` | `bg-surface-hover` | `#171717` | `#F0F0F0` | 15.73 | AAA |
| ⚠️ `text-secondary` | `bg-surface-hover` | `#737373` | `#F0F0F0` | 4.16 | AA-large only |
| ❌ `text-subdued` | `bg-surface-hover` | `#9E9E9E` | `#F0F0F0` | 2.35 | FAIL |
| ⚠️ `text-link` | `bg-surface-hover` | `#1570EF` | `#F0F0F0` | 4.01 | AA-large only |
| ✓ `text-primary` | `bg-surface-inset` | `#171717` | `#F0F0F0` | 15.73 | AAA |
| ⚠️ `text-secondary` | `bg-surface-inset` | `#737373` | `#F0F0F0` | 4.16 | AA-large only |
| ❌ `text-subdued` | `bg-surface-inset` | `#9E9E9E` | `#F0F0F0` | 2.35 | FAIL |
| ⚠️ `text-link` | `bg-surface-inset` | `#1570EF` | `#F0F0F0` | 4.01 | AA-large only |
| ✓ `text-primary` | `bg-surface-inset-hover` | `#171717` | `#E7E7E7` | 14.50 | AAA |
| ⚠️ `text-secondary` | `bg-surface-inset-hover` | `#737373` | `#E7E7E7` | 3.83 | AA-large only |
| ❌ `text-subdued` | `bg-surface-inset-hover` | `#9E9E9E` | `#E7E7E7` | 2.17 | FAIL |
| ⚠️ `text-link` | `bg-surface-inset-hover` | `#1570EF` | `#E7E7E7` | 3.70 | AA-large only |
| ✓ `text-inverse` | `bg-inverse` | `#FFFFFF` | `#242424` | 15.52 | AAA |
| ✓ `text-inverse` | `bg-inverse-hover` | `#FFFFFF` | `#363636` | 12.08 | AAA |
| ✓ `text-inverse` | `button-bg-primary` | `#FFFFFF` | `#171717` | 17.93 | AAA |
| ✓ `text-inverse` | `button-bg-primary-hover` | `#FFFFFF` | `#242424` | 15.52 | AAA |
| ⚠️ `text-inverse` | `button-bg-destructive` | `#FFFFFF` | `#F13636` | 3.95 | AA-large only |
| ⚠️ `text-inverse` | `button-bg-destructive-hover` | `#FFFFFF` | `#EC2222` | 4.36 | AA-large only |
| ✓ `text-primary` | `bg-info/5 (over container)` | `#171717` | `#f3f8fe` | 16.79 | AAA |
| ⚠️ `text-secondary` | `bg-info/5 (over container)` | `#737373` | `#f3f8fe` | 4.44 | AA-large only |
| ✓ `text-info` *(non-text 3:1)* | `bg-info/5 (over container)` | `#1570EF` | `#f3f8fe` | 4.28 | PASS |
| ✓ `text-primary` | `bg-info/10 (over container)` | `#171717` | `#e8f1fd` | 15.74 | AAA |
| ⚠️ `text-secondary` | `bg-info/10 (over container)` | `#737373` | `#e8f1fd` | 4.16 | AA-large only |
| ✓ `text-info` *(non-text 3:1)* | `bg-info/10 (over container)` | `#1570EF` | `#e8f1fd` | 4.01 | PASS |
| ✓ `text-primary` | `bg-info/20 (over container)` | `#171717` | `#d0e2fc` | 13.63 | AAA |
| ⚠️ `text-secondary` | `bg-info/20 (over container)` | `#737373` | `#d0e2fc` | 3.61 | AA-large only |
| ✓ `text-info` *(non-text 3:1)* | `bg-info/20 (over container)` | `#1570EF` | `#d0e2fc` | 3.47 | PASS |
| ✓ `text-primary` | `bg-success/5 (over container)` | `#171717` | `#f3fbf7` | 17.03 | AAA |
| ✓ `text-secondary` | `bg-success/5 (over container)` | `#737373` | `#f3fbf7` | 4.51 | AA |
| ❌ `text-success` *(non-text 3:1)* | `bg-success/5 (over container)` | `#10A861` | `#f3fbf7` | 2.94 | FAIL |
| ✓ `text-primary` | `bg-success/10 (over container)` | `#171717` | `#e7f6ef` | 16.07 | AAA |
| ⚠️ `text-secondary` | `bg-success/10 (over container)` | `#737373` | `#e7f6ef` | 4.25 | AA-large only |
| ❌ `text-success` *(non-text 3:1)* | `bg-success/10 (over container)` | `#10A861` | `#e7f6ef` | 2.77 | FAIL |
| ✓ `text-primary` | `bg-success/20 (over container)` | `#171717` | `#cfeedf` | 14.47 | AAA |
| ⚠️ `text-secondary` | `bg-success/20 (over container)` | `#737373` | `#cfeedf` | 3.83 | AA-large only |
| ❌ `text-success` *(non-text 3:1)* | `bg-success/20 (over container)` | `#10A861` | `#cfeedf` | 2.49 | FAIL |
| ✓ `text-primary` | `bg-warning/5 (over container)` | `#171717` | `#fdf7f2` | 16.87 | AAA |
| ⚠️ `text-secondary` | `bg-warning/5 (over container)` | `#737373` | `#fdf7f2` | 4.46 | AA-large only |
| ✓ `text-warning` *(non-text 3:1)* | `bg-warning/5 (over container)` | `#DC6803` | `#fdf7f2` | 3.28 | PASS |
| ✓ `text-primary` | `bg-warning/10 (over container)` | `#171717` | `#fcf0e6` | 16.00 | AAA |
| ⚠️ `text-secondary` | `bg-warning/10 (over container)` | `#737373` | `#fcf0e6` | 4.23 | AA-large only |
| ✓ `text-warning` *(non-text 3:1)* | `bg-warning/10 (over container)` | `#DC6803` | `#fcf0e6` | 3.11 | PASS |
| ✓ `text-primary` | `bg-warning/20 (over container)` | `#171717` | `#f8e1cd` | 14.21 | AAA |
| ⚠️ `text-secondary` | `bg-warning/20 (over container)` | `#737373` | `#f8e1cd` | 3.76 | AA-large only |
| ❌ `text-warning` *(non-text 3:1)* | `bg-warning/20 (over container)` | `#DC6803` | `#f8e1cd` | 2.76 | FAIL |
| ✓ `text-primary` | `bg-destructive/5 (over container)` | `#171717` | `#fef4f4` | 16.61 | AAA |
| ⚠️ `text-secondary` | `bg-destructive/5 (over container)` | `#737373` | `#fef4f4` | 4.39 | AA-large only |
| ✓ `text-destructive` *(non-text 3:1)* | `bg-destructive/5 (over container)` | `#EC2222` | `#fef4f4` | 4.04 | PASS |
| ✓ `text-primary` | `bg-destructive/10 (over container)` | `#171717` | `#fde9e9` | 15.37 | AAA |
| ⚠️ `text-secondary` | `bg-destructive/10 (over container)` | `#737373` | `#fde9e9` | 4.07 | AA-large only |
| ✓ `text-destructive` *(non-text 3:1)* | `bg-destructive/10 (over container)` | `#EC2222` | `#fde9e9` | 3.74 | PASS |
| ✓ `text-primary` | `bg-destructive/20 (over container)` | `#171717` | `#fbd3d3` | 13.11 | AAA |
| ⚠️ `text-secondary` | `bg-destructive/20 (over container)` | `#737373` | `#fbd3d3` | 3.47 | AA-large only |
| ✓ `text-destructive` *(non-text 3:1)* | `bg-destructive/20 (over container)` | `#EC2222` | `#fbd3d3` | 3.19 | PASS |
| ✓ `text-primary` | `tab-item-active` | `#171717` | `#FFFFFF` | 17.93 | AAA |
| ✓ `text-secondary` | `tab-item-active` | `#737373` | `#FFFFFF` | 4.74 | AA |

## Dark mode

| Foreground | Background | Foreground hex | Background hex | Ratio | Verdict |
|---|---|---|---|---|---|
| ✓ `text-primary` | `bg-container` | `#FFFFFF` | `#171717` | 17.93 | AAA |
| ✓ `text-secondary` | `bg-container` | `#CFCFCF` | `#171717` | 11.51 | AAA |
| ⚠️ `text-subdued` | `bg-container` | `#737373` | `#171717` | 3.78 | AA-large only |
| ✓ `text-link` | `bg-container` | `#2E90FA` | `#171717` | 5.54 | AA |
| ✓ `text-primary` | `bg-container-hover` | `#FFFFFF` | `#242424` | 15.52 | AAA |
| ✓ `text-secondary` | `bg-container-hover` | `#CFCFCF` | `#242424` | 9.96 | AAA |
| ⚠️ `text-subdued` | `bg-container-hover` | `#737373` | `#242424` | 3.27 | AA-large only |
| ✓ `text-link` | `bg-container-hover` | `#2E90FA` | `#242424` | 4.79 | AA |
| ✓ `text-primary` | `bg-container-inset` | `#FFFFFF` | `#242424` | 15.52 | AAA |
| ✓ `text-secondary` | `bg-container-inset` | `#CFCFCF` | `#242424` | 9.96 | AAA |
| ⚠️ `text-subdued` | `bg-container-inset` | `#737373` | `#242424` | 3.27 | AA-large only |
| ✓ `text-link` | `bg-container-inset` | `#2E90FA` | `#242424` | 4.79 | AA |
| ✓ `text-primary` | `bg-container-inset-hover` | `#FFFFFF` | `#363636` | 12.08 | AAA |
| ✓ `text-secondary` | `bg-container-inset-hover` | `#CFCFCF` | `#363636` | 7.76 | AAA |
| ❌ `text-subdued` | `bg-container-inset-hover` | `#737373` | `#363636` | 2.55 | FAIL |
| ⚠️ `text-link` | `bg-container-inset-hover` | `#2E90FA` | `#363636` | 3.73 | AA-large only |
| ✓ `text-primary` | `bg-surface` | `#FFFFFF` | `#0B0B0B` | 19.68 | AAA |
| ✓ `text-secondary` | `bg-surface` | `#CFCFCF` | `#0B0B0B` | 12.63 | AAA |
| ⚠️ `text-subdued` | `bg-surface` | `#737373` | `#0B0B0B` | 4.15 | AA-large only |
| ✓ `text-link` | `bg-surface` | `#2E90FA` | `#0B0B0B` | 6.08 | AA |
| ✓ `text-primary` | `bg-surface-hover` | `#FFFFFF` | `#242424` | 15.52 | AAA |
| ✓ `text-secondary` | `bg-surface-hover` | `#CFCFCF` | `#242424` | 9.96 | AAA |
| ⚠️ `text-subdued` | `bg-surface-hover` | `#737373` | `#242424` | 3.27 | AA-large only |
| ✓ `text-link` | `bg-surface-hover` | `#2E90FA` | `#242424` | 4.79 | AA |
| ✓ `text-primary` | `bg-surface-inset` | `#FFFFFF` | `#242424` | 15.52 | AAA |
| ✓ `text-secondary` | `bg-surface-inset` | `#CFCFCF` | `#242424` | 9.96 | AAA |
| ⚠️ `text-subdued` | `bg-surface-inset` | `#737373` | `#242424` | 3.27 | AA-large only |
| ✓ `text-link` | `bg-surface-inset` | `#2E90FA` | `#242424` | 4.79 | AA |
| ✓ `text-primary` | `bg-surface-inset-hover` | `#FFFFFF` | `#242424` | 15.52 | AAA |
| ✓ `text-secondary` | `bg-surface-inset-hover` | `#CFCFCF` | `#242424` | 9.96 | AAA |
| ⚠️ `text-subdued` | `bg-surface-inset-hover` | `#737373` | `#242424` | 3.27 | AA-large only |
| ✓ `text-link` | `bg-surface-inset-hover` | `#2E90FA` | `#242424` | 4.79 | AA |
| ✓ `text-inverse` | `bg-inverse` | `#171717` | `#FFFFFF` | 17.93 | AAA |
| ✓ `text-inverse` | `bg-inverse-hover` | `#171717` | `#F0F0F0` | 15.73 | AAA |
| ✓ `text-inverse` | `button-bg-primary` | `#171717` | `#FFFFFF` | 17.93 | AAA |
| ✓ `text-inverse` | `button-bg-primary-hover` | `#171717` | `#F7F7F7` | 16.73 | AAA |
| ✓ `text-inverse` | `button-bg-destructive` | `#171717` | `#ED4E4E` | 4.95 | AA |
| ✓ `text-inverse` | `button-bg-destructive-hover` | `#171717` | `#F13636` | 4.54 | AA |
| ✓ `text-primary` | `bg-info/5 (over container)` | `#FFFFFF` | `#181d22` | 16.97 | AAA |
| ✓ `text-secondary` | `bg-info/5 (over container)` | `#CFCFCF` | `#181d22` | 10.89 | AAA |
| ✓ `text-info` *(non-text 3:1)* | `bg-info/5 (over container)` | `#2E90FA` | `#181d22` | 5.24 | PASS |
| ✓ `text-primary` | `bg-info/10 (over container)` | `#FFFFFF` | `#19232e` | 15.89 | AAA |
| ✓ `text-secondary` | `bg-info/10 (over container)` | `#CFCFCF` | `#19232e` | 10.20 | AAA |
| ✓ `text-info` *(non-text 3:1)* | `bg-info/10 (over container)` | `#2E90FA` | `#19232e` | 4.91 | PASS |
| ✓ `text-primary` | `bg-info/20 (over container)` | `#FFFFFF` | `#1c2f44` | 13.64 | AAA |
| ✓ `text-secondary` | `bg-info/20 (over container)` | `#CFCFCF` | `#1c2f44` | 8.76 | AAA |
| ✓ `text-info` *(non-text 3:1)* | `bg-info/20 (over container)` | `#2E90FA` | `#1c2f44` | 4.21 | PASS |
| ✓ `text-primary` | `bg-success/5 (over container)` | `#FFFFFF` | `#171f1b` | 16.82 | AAA |
| ✓ `text-secondary` | `bg-success/5 (over container)` | `#CFCFCF` | `#171f1b` | 10.80 | AAA |
| ✓ `text-success` *(non-text 3:1)* | `bg-success/5 (over container)` | `#12B76A` | `#171f1b` | 6.41 | PASS |
| ✓ `text-primary` | `bg-success/10 (over container)` | `#FFFFFF` | `#17271f` | 15.60 | AAA |
| ✓ `text-secondary` | `bg-success/10 (over container)` | `#CFCFCF` | `#17271f` | 10.01 | AAA |
| ✓ `text-success` *(non-text 3:1)* | `bg-success/10 (over container)` | `#12B76A` | `#17271f` | 5.95 | PASS |
| ✓ `text-primary` | `bg-success/20 (over container)` | `#FFFFFF` | `#163728` | 13.03 | AAA |
| ✓ `text-secondary` | `bg-success/20 (over container)` | `#CFCFCF` | `#163728` | 8.37 | AAA |
| ✓ `text-success` *(non-text 3:1)* | `bg-success/20 (over container)` | `#12B76A` | `#163728` | 4.97 | PASS |
| ✓ `text-primary` | `bg-warning/5 (over container)` | `#FFFFFF` | `#231f18` | 16.40 | AAA |
| ✓ `text-secondary` | `bg-warning/5 (over container)` | `#CFCFCF` | `#231f18` | 10.53 | AAA |
| ✓ `text-warning` *(non-text 3:1)* | `bg-warning/5 (over container)` | `#FDB022` | `#231f18` | 8.91 | PASS |
| ✓ `text-primary` | `bg-warning/10 (over container)` | `#FFFFFF` | `#2e2618` | 14.93 | AAA |
| ✓ `text-secondary` | `bg-warning/10 (over container)` | `#CFCFCF` | `#2e2618` | 9.58 | AAA |
| ✓ `text-warning` *(non-text 3:1)* | `bg-warning/10 (over container)` | `#FDB022` | `#2e2618` | 8.11 | PASS |
| ✓ `text-primary` | `bg-warning/20 (over container)` | `#FFFFFF` | `#453619` | 11.70 | AAA |
| ✓ `text-secondary` | `bg-warning/20 (over container)` | `#CFCFCF` | `#453619` | 7.51 | AAA |
| ✓ `text-warning` *(non-text 3:1)* | `bg-warning/20 (over container)` | `#FDB022` | `#453619` | 6.36 | PASS |
| ✓ `text-primary` | `bg-destructive/5 (over container)` | `#FFFFFF` | `#221a1a` | 17.06 | AAA |
| ✓ `text-secondary` | `bg-destructive/5 (over container)` | `#CFCFCF` | `#221a1a` | 10.95 | AAA |
| ✓ `text-destructive` *(non-text 3:1)* | `bg-destructive/5 (over container)` | `#ED4E4E` | `#221a1a` | 4.71 | PASS |
| ✓ `text-primary` | `bg-destructive/10 (over container)` | `#FFFFFF` | `#2c1d1d` | 16.15 | AAA |
| ✓ `text-secondary` | `bg-destructive/10 (over container)` | `#CFCFCF` | `#2c1d1d` | 10.36 | AAA |
| ✓ `text-destructive` *(non-text 3:1)* | `bg-destructive/10 (over container)` | `#ED4E4E` | `#2c1d1d` | 4.46 | PASS |
| ✓ `text-primary` | `bg-destructive/20 (over container)` | `#FFFFFF` | `#422222` | 14.16 | AAA |
| ✓ `text-secondary` | `bg-destructive/20 (over container)` | `#CFCFCF` | `#422222` | 9.09 | AAA |
| ✓ `text-destructive` *(non-text 3:1)* | `bg-destructive/20 (over container)` | `#ED4E4E` | `#422222` | 3.91 | PASS |
| ✓ `text-primary` | `tab-item-active` | `#FFFFFF` | `#363636` | 12.08 | AAA |
| ✓ `text-secondary` | `tab-item-active` | `#CFCFCF` | `#363636` | 7.76 | AAA |

## Summary of below-AA findings

| Mode | Foreground | Background | Ratio | Verdict | Kind |
|---|---|---|---|---|---|
| light | `text-subdued` | `bg-container` | 2.68 | FAIL | text |
| light | `text-secondary` | `bg-container-hover` | 4.43 | AA-large only | text |
| light | `text-subdued` | `bg-container-hover` | 2.50 | FAIL | text |
| light | `text-link` | `bg-container-hover` | 4.27 | AA-large only | text |
| light | `text-secondary` | `bg-container-inset` | 4.43 | AA-large only | text |
| light | `text-subdued` | `bg-container-inset` | 2.50 | FAIL | text |
| light | `text-link` | `bg-container-inset` | 4.27 | AA-large only | text |
| light | `text-secondary` | `bg-container-inset-hover` | 4.16 | AA-large only | text |
| light | `text-subdued` | `bg-container-inset-hover` | 2.35 | FAIL | text |
| light | `text-link` | `bg-container-inset-hover` | 4.01 | AA-large only | text |
| light | `text-secondary` | `bg-surface` | 4.43 | AA-large only | text |
| light | `text-subdued` | `bg-surface` | 2.50 | FAIL | text |
| light | `text-link` | `bg-surface` | 4.27 | AA-large only | text |
| light | `text-secondary` | `bg-surface-hover` | 4.16 | AA-large only | text |
| light | `text-subdued` | `bg-surface-hover` | 2.35 | FAIL | text |
| light | `text-link` | `bg-surface-hover` | 4.01 | AA-large only | text |
| light | `text-secondary` | `bg-surface-inset` | 4.16 | AA-large only | text |
| light | `text-subdued` | `bg-surface-inset` | 2.35 | FAIL | text |
| light | `text-link` | `bg-surface-inset` | 4.01 | AA-large only | text |
| light | `text-secondary` | `bg-surface-inset-hover` | 3.83 | AA-large only | text |
| light | `text-subdued` | `bg-surface-inset-hover` | 2.17 | FAIL | text |
| light | `text-link` | `bg-surface-inset-hover` | 3.70 | AA-large only | text |
| light | `text-inverse` | `button-bg-destructive` | 3.95 | AA-large only | text |
| light | `text-inverse` | `button-bg-destructive-hover` | 4.36 | AA-large only | text |
| light | `text-secondary` | `bg-info/5 (over container)` | 4.44 | AA-large only | text |
| light | `text-secondary` | `bg-info/10 (over container)` | 4.16 | AA-large only | text |
| light | `text-secondary` | `bg-info/20 (over container)` | 3.61 | AA-large only | text |
| light | `text-success` | `bg-success/5 (over container)` | 2.94 | FAIL | non-text |
| light | `text-secondary` | `bg-success/10 (over container)` | 4.25 | AA-large only | text |
| light | `text-success` | `bg-success/10 (over container)` | 2.77 | FAIL | non-text |
| light | `text-secondary` | `bg-success/20 (over container)` | 3.83 | AA-large only | text |
| light | `text-success` | `bg-success/20 (over container)` | 2.49 | FAIL | non-text |
| light | `text-secondary` | `bg-warning/5 (over container)` | 4.46 | AA-large only | text |
| light | `text-secondary` | `bg-warning/10 (over container)` | 4.23 | AA-large only | text |
| light | `text-secondary` | `bg-warning/20 (over container)` | 3.76 | AA-large only | text |
| light | `text-warning` | `bg-warning/20 (over container)` | 2.76 | FAIL | non-text |
| light | `text-secondary` | `bg-destructive/5 (over container)` | 4.39 | AA-large only | text |
| light | `text-secondary` | `bg-destructive/10 (over container)` | 4.07 | AA-large only | text |
| light | `text-secondary` | `bg-destructive/20 (over container)` | 3.47 | AA-large only | text |
| dark | `text-subdued` | `bg-container` | 3.78 | AA-large only | text |
| dark | `text-subdued` | `bg-container-hover` | 3.27 | AA-large only | text |
| dark | `text-subdued` | `bg-container-inset` | 3.27 | AA-large only | text |
| dark | `text-subdued` | `bg-container-inset-hover` | 2.55 | FAIL | text |
| dark | `text-link` | `bg-container-inset-hover` | 3.73 | AA-large only | text |
| dark | `text-subdued` | `bg-surface` | 4.15 | AA-large only | text |
| dark | `text-subdued` | `bg-surface-hover` | 3.27 | AA-large only | text |
| dark | `text-subdued` | `bg-surface-inset` | 3.27 | AA-large only | text |
| dark | `text-subdued` | `bg-surface-inset-hover` | 3.27 | AA-large only | text |