-- 0006 · 增量迁移示例：加标签列 + GIN 索引

ALTER TABLE bookings ADD COLUMN IF NOT EXISTS tags text[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS bookings_tags_gin ON bookings USING gin (tags);

COMMENT ON COLUMN bookings.tags IS '自定义标签，例如 {"候选人面试","对外"}';

UPDATE bookings SET tags = ARRAY['demo'] WHERE tags = '{}';
