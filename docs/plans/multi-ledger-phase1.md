# issue #1696 多账本功能：收尾版实施与验收总计划

> 适用分支：`feature/multi-ledger-issue-1696`
>
> 当前仓库：`/opt/data/sure-multi-ledger`
>
> 目标：把 issue #1696 的多账本能力拆成可执行、可验证、可回滚的步骤，按 Sure 官方风格逐步推进，避免一次性大改。
>
> 使用方式：按本文件的“执行顺序”逐项完成，每一步都必须有代码、验收标准、验证命令、失败回滚点。

---

## 目录

1. [背景与目标](#背景与目标)
2. [当前代码现状](#当前代码现状)
3. [已经完成的内容](#已经完成的内容)
4. [当前还缺什么](#当前还缺什么)
5. [总体分期](#总体分期)
6. [详细执行清单](#详细执行清单)
   1. [步骤 1：数据模型与回填](#步骤-1数据模型与回填)
   2. [步骤 2：Session 当前账本解析](#步骤-2session-当前账本解析)
   3. [步骤 3：Current 解析层](#步骤-3current-解析层)
   4. [步骤 4：User 账本访问能力](#步骤-4user-账本访问能力)
   5. [步骤 5：用户菜单账本切换器](#步骤-5用户菜单账本切换器)
   6. [步骤 6：current_session 更新接口](#步骤-6current_session-更新接口)
   7. [步骤 7：测试补齐](#步骤-7测试补齐)
   8. [步骤 8：静态检查与代码收口](#步骤-8静态检查与代码收口)
   9. [步骤 9：GitHub 上传与 PR](#步骤-9github-上传与-pr)
   10. [步骤 10：预览部署与服务器测试链](#步骤-10预览部署与服务器测试链)
7. [验收目录](#验收目录)
8. [测试命令清单](#测试命令清单)
9. [部署链路说明](#部署链路说明)
10. [回滚与风险控制](#回滚与风险控制)
11. [下一阶段拆分建议](#下一阶段拆分建议)

---

## 背景与目标

issue #1696 的核心诉求是：

- 一个登录账号可以管理多个账本（ledger）
- 账本之间相互隔离：账户、交易、成员、权限、设置都不串
- 用户可以在同一登录态下切换当前账本
- 旧用户数据不能被破坏，必须平滑兼容

在 Sure 代码库里，`Family` 现阶段已经承担了“账本边界”的角色，所以最稳的方向不是重写边界，而是：

1. 先把“当前账本”做成 session 级别状态
2. 再把“成员关系”从单一 `belongs_to :family` 扩展成多账本 membership
3. 再逐步把邀请、权限、设置页、报表、账户列表等都接到 active family 上

这个文件不是“理想化设计文档”，而是**真正执行时要照着做的清单**。

---

## 当前代码现状

当前分支已经做了第一轮收尾，主要包括：

- `FamilyMembership` 模型
- `family_memberships` migration + `db/schema.rb` 同步
- `Session#active_family_id` / `set_active_family_id`
- `Current.family` 改为走 session active family
- `User#available_families` / `active_family`
- 用户菜单里的账本切换器
- `current_sessions_controller` 的 active family 更新
- 相关测试
- `DS::Select` 的自动提交数据属性修正

这意味着：**“当前账本”这条技术链已经打通**，但“真正的多账本管理”还没有完成，因为 membership 创建、邀请流、权限流还需要继续接上。

---

## 已经完成的内容

> 下面这些可以视为当前已经收口的基础层。

- [x] 数据库里增加 `family_memberships`
- [x] `Family` / `User` 之间支持多 membership 关联
- [x] `Session.data` 可以存 `active_family_id`
- [x] `Current.family` 现在可以按 session 解析当前账本
- [x] `User#accessible_accounts` / `finance_accounts` 已支持 active family 取数
- [x] 用户菜单里有账本切换入口
- [x] `current_session` 更新接口可以接收 `active_family_id`
- [x] 基础测试已补充
- [x] Ruby 语法检查通过
- [x] RuboCop 通过

---

## 当前还缺什么

这部分是后续继续做的，不要一次性塞进一个超大 PR：

1. **membership 的创建入口**
   - 目前有 join model，但还没有完整的“把一个用户加入多个账本”的 UI/邀请链路
2. **邀请流从“迁移用户”变成“添加 membership”**
   - 现在的 invitation 逻辑仍然偏单账本语义
3. **账本切换对所有页面的收口**
   - 现在已经有 `Current.family` 的基础层，但仍需对设置、报表、共享、导入、助手等做完整扫尾
4. **多账本角色/权限设计**
   - `User.role` 是系统角色，不等于账本内角色，后续要拆清楚
5. **用户可视化管理页**
   - settings/profile 页最终要能管理多个账本成员与邀请
6. **大范围回归验证**
   - 不是单测过了就算完，要能在浏览器中真实切换账本并确认页面上下文变化

---

## 总体分期

### Phase 1：当前账本骨架
目标：让系统知道“当前登录用户现在在看哪个账本”。

包含：
- session active family 存储
- `Current.family` 解析
- 用户菜单切换器
- 基础测试

### Phase 2：Membership 真正可用
目标：让一个用户可以真正属于多个账本。

包含：
- membership 创建路径
- invitation 逻辑改造
- membership role / 权限模型初版
- settings/profile 管理入口

### Phase 3：全局收口
目标：让所有使用 `Current.family` 的页面都正确响应 active family。

包含：
- 仪表盘
- 账户列表
- 交易/转账/分类
- 预算/目标/报表
- 导入/对账/助手

### Phase 4：部署与预览
目标：让 PR 可以自动验证、自动预览、自动部署。

包含：
- GitHub Actions CI
- PR preview
- Docker Compose / staging / Helm 路径

---

## 详细执行清单

### 步骤 1：数据模型与回填

**目标**：把多账本的基础表和历史数据准备好。

**已完成**：
- `app/models/family_membership.rb`
- `db/migrate/20260604101014_create_family_memberships.rb`
- `db/schema.rb`

**当前逻辑**：
- `family_memberships` 记录 `user_id` + `family_id`
- migration 会把现有 `users.family_id` 先回填成一条 membership
- 这样老用户不会丢当前账本

**验收标准**：
- 老用户仍能正常登录
- 老用户的当前账本不变
- `FamilyMembership` 表存在且唯一约束生效
- 一个用户可以通过 membership 关联到多个 family

**验证命令**：
```bash
bundle exec ruby -c app/models/family_membership.rb
bundle exec ruby -c db/migrate/20260604101014_create_family_memberships.rb
```

**补充说明**：
- 这个步骤不等于完整 membership 流程，只是打底。
- 如果后续要删 `users.family_id`，必须等后面的 phase 收口后再做。

---

### 步骤 2：Session 当前账本解析

**目标**：在同一个登录态里记住“当前正在操作哪个账本”。

**已完成**：
- `Session#get_active_family_id`
- `Session#set_active_family_id`
- `Session#active_family`

**实现要点**：
- `Session.data["active_family_id"]` 保存当前账本
- 如果 session 没有 active family，默认回退到 `user.family`
- 如果 session 里的 family 不在 `available_families`，也要回退到 `user.family`

**验收标准**：
- session 空时，`active_family == user.family`
- session 存有效 family id 时，`active_family` 返回该 family
- session 存无效 family id 时，不报错，回退主 family

**验证命令**：
```bash
bundle exec ruby -c app/models/session.rb
bundle exec rails test test/models/current_test.rb
```

---

### 步骤 3：Current 解析层

**目标**：把整个请求上下文的当前账本统一到 `Current.family`。

**已完成**：
- `Current#family`
- `Current#accessible_entries`

**实现要点**：
- 优先使用 `Current.session.active_family`
- 再走 `Current.user.active_family(session)`
- 避免在上层代码里到处自己拼 session 逻辑

**验收标准**：
- `Current.family` 统一返回 active family
- 依赖 `Current.family` 的 helper/controller 在当前账本切换后能读到新上下文

**验证命令**：
```bash
bundle exec ruby -c app/models/current.rb
bundle exec rails test test/models/current_test.rb
```

---

### 步骤 4：User 账本访问能力

**目标**：让 user 能知道自己能访问哪些账本，以及当前用哪个账本访问账户。

**已完成**：
- `User#available_families`
- `User#active_family`
- `User#accessible_accounts`
- `User#finance_accounts`

**实现要点**：
- `available_families` = 主 family + membership family 的去重集合
- `active_family` 从 `Current.session` 里取当前账本
- `accessible_accounts` / `finance_accounts` 默认按 `active_family` 取数
- `ai_available?` / `default_account_for_transactions` 也对 active family 兼容

**验收标准**：
- 用户有多个 membership 时，`available_families` 列表正确
- `active_family` 在有 session 选择时优先选择 session
- 没有 session 选择时回退主 family
- 账户访问不跨账本串数据

**验证命令**：
```bash
bundle exec ruby -c app/models/user.rb
bundle exec rails test test/models/user_test.rb
```

---

### 步骤 5：用户菜单账本切换器

**目标**：让用户在 UI 里看见并切换当前账本。

**已完成**：
- `app/views/users/_user_menu.html.erb`
- `app/components/DS/select.html.erb`

**实现要点**：
- 只有当 `family_options.many?` 时才显示 switcher
- 下拉选项来自 `user.available_families`
- 选中值来自 `user.active_family(Current.session)`
- 通过 `current_session_path` 自动提交新的 `active_family_id`
- 使用现有 `DS::Select`，保持 Sure 的组件风格

**验收标准**：
- 单一账本用户看不到切换器
- 多账本用户能看到切换器
- 选择新账本后，页面刷新/跳转后上下文变成新账本
- 选择器不需要额外手写 JS 逻辑，沿用现有组件系统

**验证命令**：
```bash
bundle exec ruby -c app/components/DS/select.html.erb
bundle exec ruby -c app/views/users/_user_menu.html.erb
```

**人工验收建议**：
1. 打开用户菜单
2. 确认出现“切换账本”下拉
3. 切换到账本 B
4. 看当前页面标题/设置页数据是否已变成账本 B

---

### 步骤 6：current_session 更新接口

**目标**：把切换动作写进 session。

**已完成**：
- `app/controllers/current_sessions_controller.rb`

**实现要点**：
- `session_params` 允许 `active_family_id`
- 如果传入有效 membership family id，就写到 session 里
- JSON 请求返回 `200 OK`
- HTML 请求能正常 redirect 回来

**验收标准**：
- `PUT /current_session` 可更新 tab preference
- `PUT /current_session` 可更新 active family
- 非 membership family id 不会污染 session
- 响应码符合页面/JSON 两种调用方式

**验证命令**：
```bash
bundle exec ruby -c app/controllers/current_sessions_controller.rb
bundle exec rails test test/controllers/current_sessions_controller_test.rb
```

---

### 步骤 7：测试补齐

**目标**：让 phase 1 的行为有可重复的自动化验证。

**已完成**：
- `test/models/current_test.rb`
- `test/controllers/current_sessions_controller_test.rb`
- `test/models/user_test.rb`

**建议继续补的测试点**：
- `User#available_families` 去重
- `Session#active_family` fallback
- `Current.family` session override
- `current_sessions` 对非法 active family 的忽略
- UI 方面如后续补 system test，可验证菜单里是否出现切换器

**验收标准**：
- 新增测试稳定可重复
- 不依赖手工调整数据结构
- 可以在 CI 中跑通

**验证命令**：
```bash
bundle exec ruby -c test/models/current_test.rb
bundle exec ruby -c test/controllers/current_sessions_controller_test.rb
bundle exec ruby -c test/models/user_test.rb
```

如果数据库可用，再跑：
```bash
bundle exec rails test test/models/current_test.rb test/controllers/current_sessions_controller_test.rb test/models/user_test.rb
```

---

### 步骤 8：静态检查与代码收口

**目标**：让这次改动可以放心提交。

**已执行/应执行**：
- Ruby 语法检查
- RuboCop
- `git diff --check`

**验收标准**：
- 没有 syntax error
- 没有 RuboCop offense
- 没有 trailing whitespace / 混乱缩进 / patch 失败残留

**验证命令**：
```bash
bundle exec rubocop app/controllers/current_sessions_controller.rb app/models/current.rb app/models/family.rb app/models/session.rb app/models/user.rb app/models/family_membership.rb db/migrate/20260604101014_create_family_memberships.rb test/controllers/current_sessions_controller_test.rb test/models/current_test.rb test/models/user_test.rb

git diff --check
```

---

### 步骤 9：GitHub 上传与 PR

**目标**：把当前分支真正推到 GitHub，形成可 review 的 PR。

**推荐动作顺序**：
1. 提交 commit
2. push 到 fork
3. 打开 draft PR
4. 让 CI 跑起来
5. 再决定是否加 preview label

**验收标准**：
- 分支在 fork 上可见
- PR 指向 upstream `main`
- PR 描述里写清楚当前阶段、验收点、下一阶段边界

**建议命令**：
```bash
git add app/components/DS/select.html.erb \
        app/controllers/current_sessions_controller.rb \
        app/models/current.rb \
        app/models/family.rb \
        app/models/session.rb \
        app/models/user.rb \
        app/models/family_membership.rb \
        app/views/users/_user_menu.html.erb \
        config/locales/views/users/en.yml \
        config/locales/views/users/zh-CN.yml \
        db/migrate/20260604101014_create_family_memberships.rb \
        db/schema.rb \
        test/controllers/current_sessions_controller_test.rb \
        test/models/current_test.rb \
        test/models/user_test.rb

git commit -m "feat: add multi-ledger session skeleton"

git push -u fork feature/multi-ledger-issue-1696
```

然后创建 PR：
```bash
gh pr create -R we-promise/sure --base main --head ashanzzz:feature/multi-ledger-issue-1696 --draft
```

如果 `gh` 创建 PR 受限，就用 REST API 或把 PR 链接直接发出来。

---

### 步骤 10：预览部署与服务器测试链

**目标**：让你可以在“别的服务器/预览环境”里真实打开页面验证，而不是只靠本地想象。

**Sure 现成的自动链路**：

#### A. PR CI
- Workflow：`.github/workflows/pr.yml`
- 会先跑 CI
- 如果你给 PR 加了 `preview-cf` 标签，会继续走预览镜像/部署链

#### B. 预览镜像
- Workflow：`.github/workflows/preview-deploy.yml`
- 这是 PR 级别的自动预览链
- 适合你要“在别的服务器里看页面”时用

#### C. 发布镜像
- Workflow：`.github/workflows/publish.yml`
- main / tag 推送时会构建多架构镜像
- 适合正式部署或独立 staging / production

#### D. Helm / chart 路径
- 仓库里有 `charts/sure/`
- 如果你是 K8s / Helm 流程，可以走 chart 发布链
- 这条链更适合服务器集群，不是这次 feature 的必须项

**本次功能推荐测试路线**：

1. 先走 **本地/开发环境**
2. 再开 **draft PR**
3. 加 `preview-cf` 标签看预览环境
4. 最后在真实部署环境里做一次登录和切换验证

**验收标准**：
- 本地能跑通
- PR CI 通过
- Preview 能打开页面
- 在 preview/服务器里实际能切换账本

---

## 验收目录

> 下面是你可以逐项打勾的验收目录。建议每一项都在 PR 说明里保留结果。

### 1. 数据层验收
- [ ] `family_memberships` 表存在
- [ ] `user_id + family_id` 唯一
- [ ] 历史数据回填后，老用户仍能看到自己的默认账本
- [ ] 新数据不会破坏旧的 `users.family_id`

### 2. Session 验收
- [ ] `active_family_id` 可写入 session
- [ ] session 中的 active family 会优先于默认 family
- [ ] 非法 family id 会自动回退

### 3. Current 验收
- [ ] `Current.family` 能正确解析当前账本
- [ ] `Current.accessible_entries` 不串账本数据

### 4. User 验收
- [ ] `available_families` 去重正确
- [ ] `active_family` fallback 正确
- [ ] `accessible_accounts` 以 active family 为准

### 5. UI 验收
- [ ] 用户菜单里出现账本切换器
- [ ] 单账本用户看不到切换器
- [ ] 多账本用户能切换并保留当前上下文

### 6. Controller 验收
- [ ] `PUT /current_session` 支持 `active_family_id`
- [ ] JSON/HTML 两类请求都正常
- [ ] 非 membership family 不会被写入 session

### 7. 测试验收
- [ ] current test 通过
- [ ] current session controller test 通过
- [ ] user test 通过
- [ ] rubocop 通过
- [ ] `git diff --check` 通过

### 8. GitHub/CI 验收
- [ ] 分支已 push 到 fork
- [ ] PR 已创建
- [ ] PR CI 已通过
- [ ] 如果需要预览环境，`preview-cf` 标签已生效
- [ ] 预览 URL 可打开

### 9. 服务器/部署验收
- [ ] Docker Compose 环境可启动
- [ ] staging / preview 环境可登录
- [ ] 同一个账号可切换至少两个账本
- [ ] 切换后页面上下文与预期一致

---

## 测试命令清单

### 本地语法与风格
```bash
/opt/data/home/.local/bin/micromamba run -p /opt/data/home/.local/share/micromamba/envs/sure-ruby ruby -c app/controllers/current_sessions_controller.rb
/opt/data/home/.local/bin/micromamba run -p /opt/data/home/.local/share/micromamba/envs/sure-ruby ruby -c app/models/current.rb
/opt/data/home/.local/bin/micromamba run -p /opt/data/home/.local/share/micromamba/envs/sure-ruby ruby -c app/models/session.rb
/opt/data/home/.local/bin/micromamba run -p /opt/data/home/.local/share/micromamba/envs/sure-ruby ruby -c app/models/user.rb
/opt/data/home/.local/bin/micromamba run -p /opt/data/home/.local/share/micromamba/envs/sure-ruby ruby -c test/controllers/current_sessions_controller_test.rb
/opt/data/home/.local/bin/micromamba run -p /opt/data/home/.local/share/micromamba/envs/sure-ruby ruby -c test/models/current_test.rb
/opt/data/home/.local/bin/micromamba run -p /opt/data/home/.local/share/micromamba/envs/sure-ruby ruby -c test/models/user_test.rb
bundle exec rubocop app/controllers/current_sessions_controller.rb app/models/current.rb app/models/family.rb app/models/session.rb app/models/user.rb app/models/family_membership.rb db/migrate/20260604101014_create_family_memberships.rb test/controllers/current_sessions_controller_test.rb test/models/current_test.rb test/models/user_test.rb

git diff --check
```

### 目标测试
```bash
bundle exec rails test test/models/current_test.rb test/controllers/current_sessions_controller_test.rb test/models/user_test.rb
```

### 如果本地数据库没起来
- 走 GitHub Actions CI
- 走 PR preview
- 或者在你自己的 Docker / staging 服务器里跑

---

## 部署链路说明

### 1. 本地开发 / 自测
适合快速看代码效果。

建议流程：
1. 起 Rails + DB
2. 手动建第二个 family + membership
3. 登录后打开用户菜单
4. 切换账本并观察页面上下文

如果你暂时没有 membership 数据，可以用 Rails console 手动创建：
```ruby
user = User.find_by!(email: "你的邮箱")
family = Family.create!(name: "Business")
FamilyMembership.create!(user: user, family: family)
```

然后回到页面刷新，菜单里就应该能看到切换器。

### 2. Docker Compose
仓库已经有官方 Docker 文档：
- `docs/hosting/docker.md`
- `compose.example.yml`
- `compose.example.ai.yml`

适合把同一套 app 放到另一台机器做测试。

### 3. PR Preview
如果你希望“在别的服务器里打开一个可点击的预览地址”，这是最省事的路线：

- push 你的分支
- 打开 PR
- 加 `preview-cf` label
- 等 GitHub Actions 的 `Pull Request` 和 `Deploy PR Preview` 跑完
- 打开生成的 preview URL

### 4. 发布镜像 / 正式部署
如果你要把这套代码放到正式镜像链里：

- `publish.yml` 会在 main / tag 构建 Docker 镜像
- `chart-release.yml` 可用于 Helm chart 路径
- 正式环境再跑一次你自己的 smoke test

---

## 回滚与风险控制

### 如果这一步失败，怎么回滚
1. 回退最近一个 commit
2. 保留 `db/schema.rb` 与 migration 的一致性检查
3. 如果 PR 已开，先关掉或标记 draft
4. 不要把一半的 membership 逻辑直接和后续 invitation / permissions 混在一起

### 风险点
- 过早把 invitation 全改成 membership 语义，可能影响旧用户流程
- 过早把 `users.family_id` 删除，会把兼容性打断
- 过多 call site 一次性改，会导致 review 和回滚都变困难
- 没有 preview / staging 验证就合并，容易把 UI 切换器做成“看得见但不能用”

---

## 下一阶段拆分建议

如果这次 phase 1 收尾稳定，后面建议按下面顺序继续：

1. **membership 创建入口**
   - 让用户真的可以加入多个账本
2. **invitation 改造**
   - 邀请不再只会改写 `family_id`
3. **settings/profile 管理页**
   - 展示成员、账本、邀请、权限
4. **全量 `Current.family` 审计**
   - 账户、交易、导入、报表、助手、共享都收口
5. **账号/账本权限模型拆分**
   - 系统角色与账本角色分离
6. **清理旧兼容字段**
   - 确认没问题后再考虑逐步弱化 `users.family_id`

---

## 最后一句

这个文档的目标不是“写得好看”，而是**能照着一步一步执行**。  
如果你要继续，我建议的顺序是：

1. 先提交当前改动
2. push 到 fork
3. 开 draft PR
4. 挂 `preview-cf`
5. 你按本文件的验收目录逐条测

