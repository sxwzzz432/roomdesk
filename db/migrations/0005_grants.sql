-- ============================================================
--  0005 · 授权：把「最小权限」落成 SQL
--
--  roomdesk_app    : 业务表 DML + 序列 + 函数执行权；不能 DDL
--  roomdesk_reader : 只读（排查 / 报表 / 外部 BI）
--
--  同时设置「默认权限」，以后新增的表自动继承，不用每次补 GRANT。
-- ============================================================

-- ---------- 业务 schema ----------
SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA roomdesk TO %I', :'app_user') \gexec
SELECT format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA roomdesk TO %I', :'app_user') \gexec
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA roomdesk TO %I', :'app_user') \gexec

SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA roomdesk TO %I', :'reader_user') \gexec
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA roomdesk TO %I', :'reader_user') \gexec

-- ---------- 报表 schema ----------
-- 物化视图归属 app（bootstrap 已给它 reporting 的 CREATE 权限），
-- 只有 owner 才能 REFRESH MATERIALIZED VIEW。
SELECT format('ALTER MATERIALIZED VIEW reporting.mv_room_daily_usage OWNER TO %I', :'app_user') \gexec
SELECT format('GRANT SELECT ON reporting.mv_room_daily_usage TO %I', :'app_user') \gexec
SELECT format('GRANT SELECT ON reporting.mv_room_daily_usage TO %I', :'reader_user') \gexec

SELECT format('GRANT SELECT, INSERT, UPDATE ON reporting.report_state TO %I', :'app_user') \gexec
SELECT format('GRANT SELECT ON reporting.report_state TO %I', :'reader_user') \gexec

-- ---------- 默认权限：以后新建的对象自动授权 ----------
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA roomdesk GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'app_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA roomdesk GRANT USAGE, SELECT ON SEQUENCES TO %I', :'app_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA roomdesk GRANT EXECUTE ON FUNCTIONS TO %I', :'app_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA roomdesk GRANT SELECT ON TABLES TO %I', :'reader_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA reporting GRANT SELECT ON TABLES TO %I', :'reader_user') \gexec
