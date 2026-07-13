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
