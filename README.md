# ibosong.github.io

个人站点，由 GitHub Pages 原生 Jekyll 构建。

## 目录结构

- `_config.yml`、`_layouts/`、`_posts/`、`_drafts/`、`assets/`：Jekyll 源文件。新文章以 Markdown 提交到 `_posts/`，文件名格式 `YYYY-MM-DD-slug.md`；草稿放 `_drafts/`（不参与线上构建）。
- `index.html`：个人信息主页（纯静态）。
- `blog/index.html`：博客文章列表页（Jekyll 模板，遍历 `site.posts`）。
- `css/`、`js/`、`lib/`、`images/`：静态资源，来自旧 Hexo NexT 主题，被主页和 Jekyll 布局共用。

历史 Hexo 生成的页面（归档、分类、关于等）已删除，旧文章已转换为 Markdown 存于 `_posts/`，URL 通过 `permalink: /:year/:month/:day/:title/` 保持不变。

## 本地预览

需要 Ruby 环境：

```bash
gem install bundler
bundle install
bundle exec jekyll serve --drafts
```

浏览器打开 http://localhost:4000。不安装 Ruby 时也可直接 push，由 GitHub Pages 构建。

## 评论区（giscus）

文章底部使用 [giscus](https://giscus.app/zh-CN)，评论保存在 `ibosong/ibosong.github.io` 的 GitHub Discussions 中。读者需要使用 GitHub 账号登录并授权后发表评论。

### 首次配置

1. 在仓库 **Settings → General → Features** 中启用 **Discussions**，并确认存在 `Announcements` 分类，类型为 **Announcement（公告）**。
2. 安装 [giscus App](https://github.com/apps/giscus)，选择 **Only select repositories**，仅授权 `ibosong.github.io`。
3. 打开 [giscus 配置页](https://giscus.app/zh-CN)，输入 `ibosong/ibosong.github.io`，选择 `Announcements` 分类。从生成的脚本中读取 `data-repo-id` 和 `data-category-id`，核实并填入 `_config.yml` 的 `giscus.repo_id` 和 `giscus.category_id`；分类名称应与 `giscus.category` 一致。这些 ID 是公开配置，不需要填写 Token 或其他密钥。
4. 配置齐全后，将 `giscus.enabled` 改为 `true` 并重新构建。当前仓库已完成配置并启用；分类 ID 留空时不会加载评论组件。

评论固定使用简体中文、浅色主题、路径映射（`pathname`）和严格匹配，启用反应及懒加载，输入框位于评论上方。首页、博客列表及标签页不加载评论组件。首次评论或反应会自动创建对应的 Discussion，无需为每篇文章提前创建。

### 关闭与维护

- 全局关闭：将 `_config.yml` 中的 `giscus.enabled` 设为 `false`。
- 单篇关闭：在文章的 YAML front matter 中添加 `comments: false`（布尔值，不加引号）。
- 评论按文章 URL 的路径关联。修改标题但保持路径不变不会改变关联；修改日期、slug 或 permalink 导致路径变化时，需要同步处理对应 Discussion 的关联。启用严格匹配后还涉及 Discussion 正文中的匹配哈希，不能只修改讨论标题，详见 [giscus 严格匹配说明](https://github.com/giscus/giscus/blob/main/ADVANCED-USAGE.md#data-strict)。
- 可在 GitHub Discussions 中管理评论；加载和登录需要读者能够访问 GitHub 与 giscus。

### 验证

构建后检查文章页恰好包含一个 `https://giscus.app/client.js` 脚本；全局关闭、配置缺失或单篇关闭时不应包含该脚本，首页、博客列表和标签页也不应包含。发布后检查桌面和手机布局，登录发送一条测试评论，刷新确认保留，并检查其他文章没有显示同一条评论、Discussions 中的关联正确。
