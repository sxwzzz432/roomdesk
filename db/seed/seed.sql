-- ============================================================
--  演示数据（幂等：重复执行不报错、不重复插）
--  由 scripts/migrate.sh 在 roomdesk 库为空时执行
-- ============================================================

INSERT INTO rooms (name, floor, capacity, equipment) VALUES
    ('F3-白鹭', 3,  4, '["projector", "whiteboard", "video_conf"]'),
    ('F3-苍鹭', 3,  8, '["projector", "whiteboard"]'),
    ('F5-云杉', 5, 12, '["projector", "video_conf", "speakerphone"]'),
    ('F5-冷杉', 5, 20, '["projector", "video_conf", "speakerphone", "whiteboard"]'),
    ('F8-观澜', 8, 40, '["led_wall", "video_conf", "speakerphone", "stage"]'),
    ('B1-小憩', -1, 2, '["whiteboard"]')
ON CONFLICT (name) DO NOTHING;

INSERT INTO staff (name, email, role) VALUES
    ('林知远', 'zhiyuan.lin@example.com', 'admin'),
    ('陈嘉禾', 'jiahe.chen@example.com',  'member'),
    ('苏晴',   'qing.su@example.com',     'member'),
    ('何书宁', 'shuning.he@example.com',  'member'),
    ('王砚',   'yan.wang@example.com',    'member'),
    ('沈牧',   'mu.shen@example.com',     'member'),
    ('罗一舟', 'yizhou.luo@example.com',  'member'),
    ('许南枝', 'nanzhi.xu@example.com',   'member')
ON CONFLICT (lower(email)) DO NOTHING;

-- 预约：day_off 相对今天，start_h/end_h 为当天小时数（15.5 = 15:30）
WITH d AS (
    SELECT date_trunc('day', now()) AS today
), src AS (
    SELECT r.id AS room_id,
           s.id AS staff_id,
           tstzrange(d.today + v.day_off * interval '1 day' + v.start_h * interval '1 hour',
                     d.today + v.day_off * interval '1 day' + v.end_h   * interval '1 hour',
                     '[)') AS period,
           v.purpose
    FROM (VALUES
            ('F3-白鹭', 'zhiyuan.lin@example.com', 0,  9.0, 10.0, '团队周会'),
            ('F3-白鹭', 'jiahe.chen@example.com',  0, 14.0, 15.5, '候选人面试'),
            ('F3-白鹭', 'qing.su@example.com',     1, 10.0, 12.0, '产品方案评审'),
            ('F3-白鹭', 'shuning.he@example.com',  3, 15.0, 16.0, '一对一沟通'),
            ('F3-苍鹭', 'yan.wang@example.com',    0, 10.0, 11.0, '新人入职培训'),
            ('F3-苍鹭', 'mu.shen@example.com',     1,  9.0,  9.5, '每日站会'),
            ('F3-苍鹭', 'yizhou.luo@example.com',  2, 13.0, 17.0, '设计冲刺'),
            ('F5-云杉', 'nanzhi.xu@example.com',   1, 14.0, 16.0, '客户方案讲解'),
            ('F5-云杉', 'zhiyuan.lin@example.com', 0, 16.0, 17.0, '技术分享：索引与执行计划'),
            ('F5-云杉', 'jiahe.chen@example.com',  2,  9.0, 12.0, 'Sprint Planning'),
            ('F5-冷杉', 'qing.su@example.com',     2, 13.0, 15.0, '季度复盘'),
            ('F5-冷杉', 'shuning.he@example.com',  0, 10.0, 11.5, '供应商沟通'),
            ('F8-观澜', 'yan.wang@example.com',    1,  9.0, 12.0, '全员大会'),
            ('F8-观澜', 'mu.shen@example.com',     3, 14.0, 18.0, '跨部门 Workshop'),
            ('B1-小憩', 'nanzhi.xu@example.com',   0, 12.0, 13.0, '安静办公')
         ) AS v(room, email, day_off, start_h, end_h, purpose)
    CROSS JOIN d
    JOIN rooms r ON r.name = v.room
    JOIN staff s ON lower(s.email) = lower(v.email)
)
INSERT INTO bookings (room_id, staff_id, period, purpose)
SELECT room_id, staff_id, period, purpose
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM bookings b WHERE b.room_id = src.room_id AND b.period = src.period
);

-- 一条已取消的预约：演示「取消后时间段释放」
WITH d AS (
    SELECT date_trunc('day', now()) AS today
), src AS (
    SELECT r.id AS room_id,
           s.id AS staff_id,
           tstzrange(d.today + interval '2 days 9 hours',
                     d.today + interval '2 days 11 hours', '[)') AS period
    FROM rooms r
    CROSS JOIN d
    JOIN staff s ON lower(s.email) = 'yizhou.luo@example.com'
    WHERE r.name = 'F5-冷杉'
)
INSERT INTO bookings (room_id, staff_id, period, purpose, status, cancelled_at)
SELECT room_id, staff_id, period, '已取消的预约（演示用）', 'cancelled', now()
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM bookings b WHERE b.room_id = src.room_id AND b.period = src.period
);

-- 种子数据进来后立刻刷一次读模型，保证报表接口开箱有数据
REFRESH MATERIALIZED VIEW reporting.mv_room_daily_usage;
