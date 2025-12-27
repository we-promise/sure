# Android 签名设置说明

## GitHub Secrets 配置

为了让 CI/CD 自动签名 APK/AAB，你需要在 GitHub 仓库中设置以下 Secrets：

### 步骤 1: 获取 Keystore Base64 编码

keystore 的 base64 编码已经生成在项目根目录的 `keystore-base64.txt` 文件中。

查看内容：
```bash
cat keystore-base64.txt
```

### 步骤 2: 在 GitHub 上添加 Secrets

前往你的 GitHub 仓库：
1. 点击 **Settings** (设置)
2. 在左侧菜单中点击 **Secrets and variables** > **Actions**
3. 点击 **New repository secret** 按钮
4. 添加以下四个 secrets：

| Secret 名称 | 值 |
|------------|-----|
| `KEYSTORE_BASE64` | 从 `keystore-base64.txt` 复制的 base64 字符串 |
| `KEY_STORE_PASSWORD` | 你的 keystore 密码 |
| `KEY_PASSWORD` | 你的 key 密码 |
| `KEY_ALIAS` | 你的 key alias |

### 步骤 3: 验证设置

设置完成后，推送代码到 main 分支或创建 Pull Request，CI/CD 将自动：
1. 运行测试
2. 构建签名的 APK
3. 构建签名的 AAB
4. 上传构建产物到 GitHub Actions artifacts

## 本地构建

本地构建已经配置好，`android/key.properties` 文件包含签名信息。

本地构建签名版本：
```bash
flutter build apk --release
flutter build appbundle --release
```

## 安全注意事项

- ✅ `key.properties` 和 keystore 文件已添加到 `.gitignore`
- ✅ 这些文件不会被提交到 Git 仓库
- ✅ CI/CD 使用 GitHub Secrets 安全存储签名信息
- ⚠️ 请妥善保管 `keystore-base64.txt` 文件，设置完 GitHub Secrets 后可以删除

## Keystore 信息

- **文件位置**: `android/app/upload-keystore.jks`
- **有效期**: 10000 天

⚠️ **重要提示**：
- 请妥善保管你的 keystore 密码、key 密码和 alias
- 这些信息只存储在本地的 `android/key.properties` 文件中（已添加到 .gitignore）
- GitHub Secrets 中也需要配置这些信息
- 请务必备份 keystore 文件，丢失后将无法更新已发布的应用！
