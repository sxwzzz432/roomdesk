-- ============================================================
--  0003 · 视图 / 物化视图（读模型）
--
--  v_confirmed_bookings : 把 tstzrange 展开成好用的列，供一切上层使用
--  reporting.mv_room_daily_usage : 按「房间 × 天」预聚合的读模型
--     - 报表接口不再扫 bookings 明细，读它
--     - 唯一索引让它支持 REFRESH ... CONCURRENTLY（刷新时不阻塞读）
--     - owner 会被改成 roomdesk_app（bootstrap 给了 reporting 的 CREATE 权限），
--       因为 REFRESH 权限只跟 owner 走
--  reporting.report_state : 新鲜度水位（读模型最后一次刷新的时间）
-- ============================================================

CREATE OR REPLACE VIEW v_confirmed_bookings AS
SELECT b.id,
       b.room_id,
       r.name  AS room_name,
       b.staff_id,
       s.name  AS staff_name,
       b.period,
       lower(b.period) AS starts_at,
       upper(b.period) AS ends_at,
       (EXTRACT(epoch FROM upper(b.period) - lower(b.period)) / 3600.0)::numeric(10, 2) AS hours,
       (lower(b.period) AT TIME ZONE 'Asia/Shanghai')::date AS book_date,
       b.purpose
FROM bookings b
JOIN rooms r ON r.id = b.room_id
JOIN staff s ON s.id = b.staff_id
WHERE b.status = 'confirmed';

-- ---------- 物化视图：房间 × 天 的预聚合 ----------
DROP MATERIALIZED VIEW IF EXISTS reporting.mv_room_daily_usage;
CREATE MATERIALIZED VIEW reporting.mv_room_daily_usage AS
SELECT b.room_id,
       b.room_name,
       b.book_date,
       count(*)                AS bookings,
       sum(b.hours)            AS total_hours,
       round(avg(b.hours), 2)  AS avg_hours,
       max(b.hours)            AS max_hours
FROM v_confirmed_bookings b
GROUP BY b.room_id, b.room_name, b.book_date
WITH DATA;

-- REFRESH MATERIALIZED VIEW CONCURRENTLY 的前提：唯一索引
CREATE UNIQUE INDEX IF NOT EXISTS mv_room_daily_usage_uniq
    ON reporting.mv_room_daily_usage (room_id, book_date);
CREATE INDEX IF NOT EXISTS mv_room_daily_usage_date
    ON reporting.mv_room_daily_usage (book_date);

-- ---------- 新鲜度水位 ----------
CREATE TABLE IF NOT EXISTS reporting.report_state (
    name         text PRIMARY KEY,
    refreshed_at timestamptz NOT NULL DEFAULT now(),
    row_count    bigint      NOT NULL DEFAULT 0,
    last_source  text        NOT NULL DEFAULT 'migration'
);
INSERT INTO reporting.report_state (name, refreshed_at, row_count, last_source)
VALUES ('mv_room_daily_usage', now(), 0, 'migration')
ON CONFLICT (name) DO NOTHING;
