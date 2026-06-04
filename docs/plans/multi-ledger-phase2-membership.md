# issue #1696 Phase 2：membership / invitation / permissions 实施总计划

> 关联 issue：`#1696`
>
> 依赖前置：`docs/plans/multi-ledger-phase1.md` 已落地并进入 PR `#2181`
>
> 当前目标：在 phase 1 的“当前账本切换骨架”之上，继续把**多账本成员关系、邀请流、成员管理页、基础权限语义**推进到可用状态。

---

## 目录

1. [本阶段目标](#本阶段目标)
2. [为什么 phase 2 不能一次性全改](#为什么-phase-2-不能一次性全改)
3. [当前阻塞点与旧语义](#当前阻塞点与旧语义)
4. [phase 2 设计原则](#phase-2-设计原则)
5. [建议拆成的 PR 序列](#建议拆成的-pr-序列)
6. [详细实施计划](#详细实施计划)
   1. [PR 2A：Invitation 改成“加 membership”，不再默认迁移 family_id](#pr-2a-invitation-改成加-membership不再默认迁移-family_id)
   2. [PR 2B：Settings Profile 成员页改成 membership 视图](#pr-2b-settings-profile-成员页改成-membership-视图)
   3. [PR 2C：成员移除从删用户改成删 membership](#pr-2c-成员移除从删用户改成删-membership)
   4. [PR 2D：账本内角色引入 membership role 桥接层](#pr-2d-账本内角色引入-membership-role-桥接层)
   5. [PR 2E：注册/登录/接受邀请链的最终收口](#pr-2e-注册登录接受邀请链的最终收口)
7. [每个 PR 的测试与验收标准](#每个-pr-的测试与验收标准)
8. [最短测试手册](#最短测试手册)
9. [风险点与回滚点](#风险点与回滚点)
10. [不在本阶段范围内的内容](#不在本阶段范围内的内容)

---

## 本阶段目标

Phase 2 要解决的不是“切换账本”本身，而是：

- 用户如何真正属于多个账本
- 邀请用户加入账本时，不再粗暴地把 `users.family_id` 改掉
- 设置页如何展示“当前账本的成员”和“当前账本的待接受邀请”
- 管理员移除成员时，应该移除**当前账本 membership**，而不是直接删除整个用户
- 后续权限重构要有一个可兼容的桥接层，不至于一次性把全仓库炸开

换句话说，phase 1 解决的是：
> “当前看哪个账本？”

phase 2 要解决的是：
> “为什么这个用户有资格看这个账本，以及怎么加入/退出这个账本？”

---

## 为什么 phase 2 不能一次性全改

当前代码库里，单账本假设嵌得很深：

- `User belongs_to :family`
- `Invitation#accept_for` 直接 `user.update!(family_id: family_id, role: role)`
- `Settings::ProfilesController#show` 用的是 `Current.family.users`
- `Settings::ProfilesController#destroy` 直接删用户
- 一堆控制器和 policy 默认把 `user.role` 当成当前账本角色

如果这一轮同时改：
- invitation
- members management
- permissions
- reports
- account sharing
- all call sites

那 PR 会非常大，review 很难，出了问题也没法快速回滚。

所以 phase 2 必须继续拆小：
1. 先把 invitation 语义改对
2. 再把成员页从 `Current.family.users` 换成 membership 视图
3. 再把移除成员改成删 membership
4. 最后才慢慢抽 `membership_role`

---

## 当前阻塞点与旧语义

下面这些是当前 phase 1 之后仍然保留的旧语义：

### 1. Invitation 仍然会迁移主 family
文件：`app/models/invitation.rb`

当前实现：
```ruby
user.update!(family_id: family_id, role: role.to_s)
```

这意味着：
- 接受邀请后，用户被“搬家”到新 family
- 这和多账本目标冲突

### 2. 邀请现有用户时，controller 会立即 accept
文件：`app/controllers/invitations_controller.rb`

当前实现：
- 如果邮箱已存在，就直接 `@invitation.accept_for(existing_user)`
- 本质还是单账本“拉人进来”逻辑

### 3. Settings profile 页看的是 `Current.family.users`
文件：
- `app/controllers/settings/profiles_controller.rb`
- `app/views/settings/profiles/show.html.erb`

这会漏掉：
- 通过 membership 属于这个账本，但 `user.family_id` 不是这个 family 的用户

### 4. 删除成员时会删掉整个用户
文件：`Settings::ProfilesController#destroy`

当前实现：
```ruby
if @user.destroy
```

这和多账本目标不兼容，因为：
- 用户可能还属于别的账本
- 用户账号不该因为离开一个账本就被删除

### 5. 当前 `user.role` 混合了“系统身份”和“账本身份”
当前大量地方写的是：
- `Current.user.admin?`
- `user.member?`
- `user.guest?`

这在单账本时代勉强成立；在多账本时代，应该问的是：
- “这个用户在当前账本里是不是 admin？”
- 而不是“这个用户这个全局 row 上是不是 admin？”

---

## phase 2 设计原则

### 原则 1：继续保留 `users.family_id` 作为兼容默认值
本阶段不要急着删除它。

它仍然承担：
- 老数据默认 family
- 老逻辑 fallback family
- 未完全迁移的 call site 的兜底兼容

### 原则 2：membership 才是“是否属于账本”的真实来源
当判断：
- 当前 family 的成员列表
- 当前 family 是否允许切换进去
- 邀请是否成功加入
- 当前 family 能否移除某成员

应逐步切到 `FamilyMembership`。

### 原则 3：先桥接，不一次性重构全局角色
不要立刻把所有 `user.admin?` 替换掉。

先加桥接方法，例如：
- `user.role_for(family)`
- `user.admin_for?(family)`
- `user.member_of?(family)`

然后逐步把高风险路径替过去。

### 原则 4：成员页优先表达“当前账本成员”
settings/profile 页展示的是：
- 当前账本 members
- 当前账本 pending invitations
- 当前账本 management actions

不是“全局用户列表”。

### 原则 5：删除成员 ≠ 删除用户
离开一个账本，只删：
- 当前账本 membership
- 当前账本 invitation（如果需要）

只有当用户明确执行账号删除，才走 `UsersController#destroy` / deactivate / purge。

---

## 建议拆成的 PR 序列

### PR 2A
**Invitation semantic bridge**
- 接受邀请时创建 membership
- 不再默认改写 `user.family_id`
- 先兼容保留 `role` 写法，但范围收窄

### PR 2B
**Settings profile membership view**
- 成员页改用 membership 数据
- pending invitation 按当前 family 展示
- UI 文案保持现有风格

### PR 2C
**Remove member = remove membership**
- 当前账本移除成员时，不删 user
- 只删 membership
- 处理 self-remove / last-admin / orphan-data 等边界

### PR 2D
**Membership role bridge**
- family_memberships 增加 role 字段
- `user.role_for(Current.family)` 桥接
- 先迁移 invitation/profile/account-management 高优先级路径

### PR 2E
**Auth / registration / invitation acceptance cleanup**
- 登录接受邀请链
- 注册接受邀请链
- OIDC / session pending invitation 链路收口

---

## 详细实施计划

## PR 2A：Invitation 改成“加 membership”，不再默认迁移 family_id

### 目标
把 invitation 从“把用户搬到这个 family”改成“给这个 user 增加当前 family 的 membership”。

### 要修改的文件
- `app/models/invitation.rb`
- `app/controllers/invitations_controller.rb`
- `app/controllers/application_controller.rb`
- `app/controllers/registrations_controller.rb`
- `test/models/invitation_test.rb`
- `test/controllers/invitations_controller_test.rb`
- 可能补充 `test/controllers/registrations_controller_test.rb`

### 核心行为改变

#### 旧行为
```ruby
user.update!(family_id: family_id, role: role.to_s)
```

#### 新行为目标
```ruby
FamilyMembership.find_or_create_by!(user: user, family: family)
# 记录或桥接 membership role
update!(accepted_at: Time.current)
```

### 这一 PR 不做的事
- 不立刻在全仓库引入 membership role 全量判断
- 不立刻删除 `users.family_id`
- 不改全局 admin/system role 定义

### 新验收标准
- 邀请现有用户时，不再把 `user.family_id` 改掉
- 邀请成功后，用户 `available_families` 中多出当前 family
- 邀请接受后，`accepted_at` 正常写入
- 登录/注册链接里通过 invitation 进入时，不会破坏用户原来的主 family

### 边界测试
- 已在同 family 中的用户再次邀请：幂等 or 合理拒绝
- 已在其他 family 中且拥有账户：不再因为“迁移 family”而报 orphan 错
- 同 email 跨 family pending invitation 规则继续生效

---

## PR 2B：Settings Profile 成员页改成 membership 视图

### 目标
让 profile/settings 页真正展示“当前账本成员”，而不是 `Current.family.users`。

### 当前问题
`Settings::ProfilesController#show` 里现在是：
```ruby
@users = Current.family.users.order(:created_at)
```

这只会列出主 family 指向当前 family 的用户，漏掉 membership 用户。

### 要修改的文件
- `app/controllers/settings/profiles_controller.rb`
- `app/views/settings/profiles/show.html.erb`
- 可能新增 helper / presenter
- `test/controllers/settings/profiles_controller_test.rb`
- 后续可考虑加 system test

### 目标数据来源
建议改成：
- `@memberships = Current.family.family_memberships.includes(:user).order(created_at: :asc)`
- 页面遍历 membership，再渲染 user 信息

### 页面目标行为
- 成员列表 = 当前账本 membership 列表
- pending invitation = 当前账本 invitation.pending
- 页面 header 仍显示 `Current.family.name`
- 管理按钮仍保留在当前账本作用域下

### 新验收标准
- membership 用户能出现在成员列表中
- 非 membership 用户不会误出现在当前账本成员列表
- pending invitations 仍正常显示
- UI 风格不跑偏，继续沿用现有 DS / section 布局

---

## PR 2C：成员移除从删用户改成删 membership

### 目标
把“从账本移除成员”改成：
- 删除当前 family 的 membership
- 不删除整个 user row

### 当前危险点
当前：
```ruby
if @user.destroy
```

这会误删：
- 该用户在别的账本的存在
- 用户自己的账号
- 后续登录能力

### 要修改的文件
- `app/controllers/settings/profiles_controller.rb`
- `app/views/settings/profiles/show.html.erb`（若按钮参数需变）
- `config/routes.rb`（如果需要从 `user_id` 改成 `membership_id` 或 member token）
- `test/controllers/settings/profiles_controller_test.rb`

### 建议新接口语义
优先按 membership 删除，而不是 user 删除，例如：
- `DELETE /settings/profile?membership_id=...`
或新增嵌套路由（后续可再整理）

### 必须处理的边界
1. admin 不能移除自己当前账本 membership（至少第一版建议禁止）
2. 如果当前账本只剩最后一个 admin，不能直接删
3. 如果用户在当前账本里拥有当前账本账户，需要先定义如何处理
4. 如果用户在其他账本有数据，不应受影响

### 新验收标准
- 移除成员后，user 仍存在
- 该用户只是看不到当前账本，不影响其他账本
- 当前账本成员列表减少 1
- 相关 pending invitation 清理逻辑按当前 family 作用域执行

---

## PR 2D：账本内角色引入 membership role 桥接层

### 目标
让 “admin/member/guest” 从全局 user role 开始向“当前账本内角色”过渡。

### 为什么现在要做
如果 invitation 已经变成 membership-only，但仍大量使用：
- `Current.user.admin?`
- `user.member?`

那跨账本后会产生语义歧义。

### 最小可行方案
给 `family_memberships` 增加 `role` 字段：
- `guest`
- `member`
- `admin`

并添加桥接方法：
- `User#membership_for(family)`
- `User#role_for(family)`
- `User#admin_for?(family)`
- `User#member_of?(family)`

### 第一批优先切换的调用点
- `InvitationsController`
- `Settings::ProfilesController`
- `UsersController` 里修改 family 属性的地方
- `AccountPolicy#create?` 这类高频权限入口

### 本 PR 仍不做
- 不要求一口气改完整个仓库的所有 `user.admin?`
- 先改“当前正在动的多账本路径”

### 验收标准
- 当前账本内角色可独立表达
- 某用户在账本 A 是 admin，在账本 B 是 member 能成立
- phase 1/2 关键路径使用 membership role 后仍兼容老数据

---

## PR 2E：注册/登录/接受邀请链的最终收口

### 目标
把 invitation token 穿过：
- 注册
- 登录
- OIDC
- MFA 后完成登录

这些路径时，都统一变成“增加 membership / 激活当前账本”，而不是“迁移主 family”。

### 涉及文件
- `app/controllers/application_controller.rb`
- `app/controllers/sessions_controller.rb`
- `app/controllers/registrations_controller.rb`
- `app/controllers/oidc_accounts_controller.rb`
- `app/controllers/mfa_controller.rb`
- 相关 controller tests

### 关键行为
当 `pending_invitation_token` 存在时：
1. 找到 pending invitation
2. accept for user -> 增加 membership
3. 视情况把新 family 设为当前 session 的 `active_family_id`
4. 显示 joined family 的 notice

### 额外建议
接受 invitation 后，最好：
```ruby
Current.session.set_active_family_id(invitation.family_id)
```
这样用户登录后直接落在新加入的账本上下文，更符合直觉。

### 验收标准
- 老注册链接仍可用
- 现有用户登录接受邀请后，不丢原主 family
- 新注册用户通过 invitation 进入后，默认进入被邀请账本
- OIDC / MFA 不会绕过 membership accept 流

---

## 每个 PR 的测试与验收标准

## PR 2A 测试
### 模型测试
- `Invitation#accept_for`：创建 membership，不改 `user.family_id`
- 已有 membership 时不重复创建
- pending / email mismatch / expired cases 仍正确

### 控制器测试
- invite existing user -> accepted invitation + new membership
- invite new email -> pending invitation + mail path
- invite existing user with prior family -> no forced migration

## PR 2B 测试
- settings profile 页能展示 membership 用户
- current family 的 pending invitations 正常
- 非当前 family membership 用户不显示

## PR 2C 测试
- 删除成员 -> membership 数量减少
- user 数量不变
- 其他 family membership 不受影响
- self remove / last admin / owner edge cases 有保护

## PR 2D 测试
- `role_for(family)` 返回正确
- `admin_for?(family)` / `member_of?(family)` 逻辑正确
- invitation 接受时 role 写入 membership

## PR 2E 测试
- session pending invitation 登录后可接受
- registration invitation 路径可接受
- OIDC flow 可接受
- 新 family 自动成为 active family（如果决定这样做）

---

## 最短测试手册

下面是给你在 preview / staging 环境里用的最短验证单。

### 准备数据
1. 准备用户 `U`
2. 准备账本 `A`
3. 准备账本 `B`
4. 确保 `U` 原本主 family 是 `A`
5. 通过 invitation 或 console 给 `U` 增加对 `B` 的 membership

### 验证 1：切换器
- 登录 `U`
- 用户菜单出现“切换账本”
- 能切到 `B`
- 刷新后仍在 `B`

### 验证 2：邀请现有用户
- 在 `A` 中邀请现有用户 `U`
- 不应把 `U.family_id` 改成 `A`
- 应新增 membership
- `U` 登录后能切到 `A`

### 验证 3：成员页
- 当前账本成员页能看到 membership 用户
- 不属于当前账本的用户不会出现
- pending invitation 正常显示

### 验证 4：移除成员
- 从账本 `B` 移除 `U`
- `U` 账号仍然存在
- `U` 不再能切换到 `B`
- `U` 仍可访问 `A`

### 验证 5：角色
- `U` 在 `A` 是 admin、在 `B` 是 member 时
- `A` 的管理操作允许
- `B` 的管理操作限制正确

---

## 风险点与回滚点

### 风险 1：旧逻辑仍依赖 `Current.family.users`
如果只改了 invitation，没改 settings/profile，就会出现：
- 实际已加入 membership
- 但成员页看不到人

### 风险 2：删除成员时误删 user
如果 destroy 路径收口不完整，极容易把“移除账本成员”做成“删除账号”。

### 风险 3：角色桥接不完整
如果某些地方已经切到 membership role，但别处仍看 `user.role`，会出现前后不一致。

### 风险 4：接受邀请后 session 没切到新账本
用户会误以为邀请失败，因为 UI 仍停留在旧账本。

### 回滚建议
- 每个 PR 保持独立可回退
- 先合 semantic bridge，再合 UI，再合 removal，再合 role bridge
- 不要把 migration + invitation rewrite + settings destroy rewrite 混成一个 commit

---

## 不在本阶段范围内的内容

下面这些明确不属于 phase 2 的最小范围：

- 报表 / 打印 / PDF / export 全量 current family 审计
- account sharing 全量 membership role 化
- budgets / goals / rules / AI assistant 全仓库权限改造
- `users.family_id` 删除
- 所有 policy 一次性改成 membership role
- mobile / API / public docs 的最终全量同步

这些应放到 phase 3/4。

---

## 建议你接下来怎么走

最稳的顺序是：

1. 先等 PR `#2181` 被 review / 测一轮
2. 然后开 **PR 2A：Invitation semantic bridge**
3. 再开 **PR 2B：Settings profile membership view**
4. 再开 **PR 2C：remove membership not user**
5. 最后看情况做 **PR 2D / 2E**

如果你要我继续，我下一步最合适的是：

- 直接开始写 **PR 2A** 的代码
- 或者我先再写一个 **超短执行版 checklist** 到仓库里，方便你现场测试
