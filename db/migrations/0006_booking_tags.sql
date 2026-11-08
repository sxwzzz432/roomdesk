-- ============================================================
--  0006 · 成长型迁移示例：加标签列 + GIN 索引
--  用来演示「迁移是增量的、可追溯的」，也演示默认权限生效
--  （新列所在表不需要额外 GRANT，因为用的是 ALTER 而不是新表）
-- ============================================================

ALTER TABLE bookings ADD COLUMN IF NOT EXISTS tags text[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS bookings_tags_gin ON bookings USING gin (tags);

COMMENT ON COLUMN bookings.tags IS '自定义标签，例如 {"候选人面试","对外"}';

-- 顺手把存量数据打个标，演示 UPDATE 型迁移
UPDATE bookings SET tags = ARRAY['demo'] WHERE tags = '{}';
