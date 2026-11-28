-- 段階4の小さな試し: Grok Bot などのボットから X・Instagram の投稿を受け取る（設計: jinsei vault hestia/projects/RSSフィーダー設計.md「小さな試し: Grok Bot から受け取る口」）
--   POST /api/social/posts・MCP（POST /api/mcp の add_posts）で入る。(platform, post_id) が重なれば飛ばす
--   media: JSON 配列 [{ type, url }]・quoted: 引用元の投稿を JSON で（空可）・数（like など）は空可
--   90 日の掃除は既読（read_at あり）だけ。未読は消さない
CREATE TABLE social_posts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  platform TEXT NOT NULL CHECK (platform IN ('x', 'instagram')),
  post_id TEXT NOT NULL,
  url TEXT NOT NULL,
  author_name TEXT,
  author_handle TEXT NOT NULL,
  author_avatar_url TEXT,
  text TEXT NOT NULL,
  media TEXT NOT NULL DEFAULT '[]',
  posted_at TEXT NOT NULL,
  like_count INTEGER,
  repost_count INTEGER,
  reply_count INTEGER,
  view_count INTEGER,
  quoted TEXT,
  source TEXT NOT NULL,
  fetched_at TEXT NOT NULL,
  read_at TEXT,
  UNIQUE (platform, post_id)
);
-- 一覧（新しい順・before で続き）と known（since 以降の post_id）
CREATE INDEX social_posts_timeline ON social_posts (platform, posted_at DESC, id DESC);
-- 90 日の掃除（既読だけ）
CREATE INDEX social_posts_read ON social_posts (read_at) WHERE read_at IS NOT NULL;
