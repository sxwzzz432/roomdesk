-- ============================================================
--  性能实验：执行计划 / 索引 / 分区剪枝 / 锁 / 慢查询
--  make bench
-- ============================================================
\timing on

\echo ''
\echo '=== 0. 数据规模与体积 ==='
SELECT (SELECT count(*) FROM rooms)    AS rooms,
       (SELECT count(*) FROM staff)    AS staff,
       (SELECT count(*) FROM bookings) AS bookings,
       pg_size_pretty(pg_database_size(current_database())) AS db_size;

\echo ''
\echo '=== 1. 可用房间查询（GiST 区间重叠 + JSONB 包含）==='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM free_rooms(now() + interval '1 day',
                         now() + interval '1 day 2 hours',
                         8,
                         ARRAY['projector']);

\echo ''
\echo '=== 2. 排他约束的真实行为：故意制造冲突 ==='
DO $$
BEGIN
    INSERT INTO bookings (room_id, staff_id, period, purpose)
    SELECT room_id, staff_id, period, '故意冲突'
      FROM bookings WHERE status = 'confirmed' LIMIT 1;
    RAISE NOTICE '意外：冲突插入成功了（约束失效？）';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE '预期内的 exclusion_violation —— 约束正常工作';
END $$;

\echo ''
\echo '=== 3. 报表两条路径对比：物化视图 vs 现场聚合 ==='
\echo '-- 3a 读物化视图（毫秒级，数据可能滞后 REFRESH_INTERVAL）'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT room_id, room_name, sum(total_hours)
  FROM reporting.mv_room_daily_usage
 WHERE book_date >= current_date - 30
 GROUP BY 1, 2
 ORDER BY 3 DESC;

\echo '-- 3b 现场扫明细（行数越多越慢）'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT room_id, sum(EXTRACT(epoch FROM ends_at - starts_at) / 3600)
  FROM v_confirmed_bookings
 WHERE starts_at >= now() - interval '30 days'
 GROUP BY 1;

\echo ''
\echo '=== 4. 分区剪枝：写了上界才能只扫一个分区 ==='
EXPLAIN (ANALYZE, COSTS OFF)
SELECT count(*) FROM booking_events
 WHERE occurred_at >= date_trunc('month', now())
   AND occurred_at <  date_trunc('month', now()) + interval '1 month';

\echo '-- 对照：只写下界时无法剪枝'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT count(*) FROM booking_events
 WHERE occurred_at >= date_trunc('month', now());

SELECT tableoid::regclass::text AS partition, count(*) AS rows
  FROM booking_events GROUP BY 1 ORDER BY 1;

\echo ''
\echo '=== 5. 索引命中情况 ==='
SELECT relname, indexrelname, idx_scan, idx_tup_read
  FROM pg_stat_user_indexes
 WHERE schemaname IN ('roomdesk', 'reporting')
 ORDER BY idx_scan DESC;

\echo ''
\echo '=== 6. 权限矩阵（谁能在哪个 schema 干什么）==='
SELECT has_schema_privilege('roomdesk_app', 'roomdesk', 'USAGE')       AS app_usage_roomdesk,
       has_schema_privilege('roomdesk_app', 'roomdesk', 'CREATE')      AS app_create_roomdesk,
       has_schema_privilege('roomdesk_app', 'reporting', 'CREATE')     AS app_create_reporting,
       has_table_privilege('roomdesk_app', 'roomdesk.bookings', 'INSERT') AS app_insert_bookings,
       has_table_privilege('roomdesk_app', 'roomdesk.bookings', 'TRUNCATE') AS app_truncate_bookings,
       has_table_privilege('roomdesk_reader', 'roomdesk.bookings', 'INSERT') AS reader_insert_bookings;

\echo ''
\echo '=== 7. 谁在连、在跑什么（连接池的价值）==='
SELECT usename, state, count(*)
  FROM pg_stat_activity
 WHERE datname = current_database()
 GROUP BY 1, 2
 ORDER BY 3 DESC;

\echo ''
\echo '=== 8. 最耗时的 SQL（pg_stat_statements）==='
SELECT calls,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       round(total_exec_time::numeric, 2) AS total_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 90) AS query
  FROM pg_stat_statements
 WHERE query NOT ILIKE '%pg_stat_statements%'
 ORDER BY total_exec_time DESC
 LIMIT 10;

\echo ''
\echo '=== 9. 死元组 / 膨胀（VACUUM 的必要性）==='
SELECT relname, n_live_tup, n_dead_tup, last_autovacuum
  FROM pg_stat_user_tables
 WHERE schemaname = 'roomdesk'
 ORDER BY n_dead_tup DESC;
