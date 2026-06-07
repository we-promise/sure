# Issue #2192 — 渠道支付标识设计文档

## 概述

支持用户在支付渠道（支付宝、微信、PayPal 等）记录交易时，标记实际资金来源（借记卡/信用卡），系统自动生成关联银行记录用于对账。

## 数据模型

### 新增字段：`transactions` 表

| 字段 | 类型 | 说明 |
|------|------|------|
| `channel_record_parent_id` | UUID, FK → transactions.id, nullable | 银行侧记录指向原渠道记录的父指针。非空 = 自动生成的渠道记录 |

### 现有字段复用

| 字段 | 用途 |
|------|------|
| `entries.excluded` | Record A（渠道侧）设为 `true`，不参与余额计算 |
| `transactions.extra["channel_payment"]` | 标记渠道侧 Record A |
| `transactions.extra["funding_account_id"]` | 记录发起时用户选的资金来源账户 |

### 数据流示例

用户创建一笔支付宝交易，选择"工行借记卡"作为资金来源：

```
Record A (渠道侧)             Record B (银行侧，自动生成)
├─ Account: 支付宝            ├─ Account: 工行借记卡
├─ Amount: -98.97             ├─ Amount: -98.97
├─ Name: "星巴克拿铁"         ├─ Name: "支付宝 - 星巴克拿铁"
├─ Entry.excluded: TRUE       ├─ Entry.excluded: FALSE（默认）
├─ extra.channel_payment: true├─ channel_record_parent_id → Record A.id
└─ extra.funding_account_id   └─ extra.channel_auto_record: true
   → 工行卡 ID
```

## 修改范围

### Phase 1 — 数据层 + API（~200 行）

**Migration**（`db/migrate/`）：
- `add_column :transactions, :channel_record_parent_id, :uuid`
- `add_index` + `add_foreign_key`

**Model — `Transaction`**：
- `belongs_to :channel_record_parent, class_name: "Transaction", optional: true`
- `has_many :channel_child_records, class_name: "Transaction", foreign_key: :channel_record_parent_id`
- Scope: `channel_auto_records` (where channel_record_parent_id not null)

**Balance fix — `Balance::SyncCache#converted_entries`**（line 37）：
- 当前：`account.entries.excluding_split_parents...`
- 改为：`account.entries.where(excluded: false).excluding_split_parents...`
- 这是核心修复：确保 `excluded=true` 的记录不参与余额计算
- **风险注意**：若现有数据中已有 excluded 记录被错误地计入余额，此修复会导致余额变化。需加 feature flag 或迁移脚本处理旧数据。

**API Controller — `Api::V1::TransactionsController#create`**：
- 检测 `params[:funding_account_id]`
- 若存在且非空：
  1. 创建 Record A（渠道侧）：`entry.excluded = true`, `extra["channel_payment"] = true`, `extra["funding_account_id"] = ...`
  2. 创建 Record B（银行侧）：account = funding_account，entry.name = `"{渠道名} - {原名称}"`, `channel_record_parent_id = A.id`, `extra["channel_auto_record"] = true`
  3. 用 `ActiveRecord::Base.transaction` 包裹
  4. 返回两个 record 的引用

**Model 常量**（`Transaction`）：
- 新增 `kind: :channel_payment`（待定，见下方讨论）

### Phase 2 — UI（~150 行）

**Transaction 表单**（`_form.html.erb`）：
- 在 account select 下方加 funding source dropdown
- 数据源：`Current.family.accounts.where(accountable_type: ["Depository", "CreditCard", "Loan"])`
- 排除当前选中的 account（不能自己 funding 自己）
- 默认空（普通交易），选中后自动触发渠道支付模式

**Stimulus controller**（`transaction_form_controller.js`）：
- 已有 controller，加 funding source change handler
- 选 funding source 后显示"渠道支付"提示

**i18n**：英文/中文各 ~5 条

### Phase 3 — UI 展示（~100 行）

**Transaction 详情页**：
- 渠道侧：显示 "资金来源：[银行名]"，链接到 Record B
- 银行侧：显示 "自动生成自 [渠道名]"，链接到 Record A
- 小 badge：🟣 "渠道" / 🟣 "自动"

**Transaction 列表**：
- Badge 显示同详情页

**View 模板**：
- `transactions/_detail.html.erb` — 加 linked record 信息
- `transactions/_list.html.erb` — 加 badge

### Phase 4 — 收尾（~50 行）

- `bin/rubocop` 检查
- `bin/rails test` 全绿
- RSwag 文档更新

---

## 待确认的设计决策

需和上游 maintainer 讨论：

1. **Balance fix 的旧数据兼容**：`Balance::SyncCache` 加 `where(excluded: false)` 后，若现有 excluded 记录曾被错误计入余额 → 余额会变化。处理方案：(a) 先写 migration 重算所有 balance snapshots，(b) feature flag 控制，(c) 不管，直接改。**倾向：方案 A**。

2. **Transaction kind 新增**：issue 未提新增 kind，但建议 `kind: :channel_payment` 便于过滤统计。**倾向：不加（保持 scope 最小）**。

3. **Editing 联动**：编辑渠道侧 record 时是否自动更新银行侧？Issue 建议 v1 不做联动。**倾向于：不做，留到后续迭代**。

4. **删除级联**：删除渠道侧 record → 同时删除银行侧 record；删除银行侧 → 仅 unlink（清 `channel_record_parent_id`）。**倾向：按 issue 建议实现**。

5. **Account subtype**：是否新增 "payment channel" 类型便于过滤？**倾向于：v1 不做，手动选**。

6. **Bulk import**：CSV 导入时自动识别渠道支付行。**倾向于：v1 不做**。

---

## 预期改动文件

```
db/migrate/XXXX_add_channel_record_parent_id_to_transactions.rb
db/schema.rb
app/models/transaction.rb                          (+~30 行)
app/models/balance/sync_cache.rb                   (+1 行 where)
app/controllers/api/v1/transactions_controller.rb  (+~30 行)
app/controllers/transactions_controller.rb         (+~10 行)
app/views/transactions/_form.html.erb              (+~20 行)
app/views/transactions/show.html.erb               (+~15 行)
app/views/transactions/_list.html.erb              (+~5 行)
app/javascript/controllers/transaction_form_controller.js  (+~15 行)
config/locales/views/transactions/en.yml           (+~5 行)
config/locales/views/transactions/zh-CN.yml        (+~5 行)
test/models/transaction_test.rb                    (+~20 行)
test/controllers/api/v1/transactions_controller_test.rb  (+~30 行)
test/system/transactions_test.rb                   (+~15 行)
```

---

## 暂不处理（留给后续 PR）

- Balance fix 旧数据迁移
- 渠道支付 CSV 导入识别
- Edit 联动
- Payment channel account subtype
- Apple Pay 特殊处理
