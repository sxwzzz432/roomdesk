-- 0005 · 最小权限：app 只有 DML + 函数执行权，reader 只读

SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA roomdesk TO %I', :'app_user') \gexec
SELECT format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA roomdesk TO %I', :'app_user') \gexec
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA roomdesk TO %I', :'app_user') \gexec

SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA roomdesk TO %I', :'reader_user') \gexec
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA roomdesk TO %I', :'reader_user') \gexec

-- 物化视图必须归 app 所有：REFRESH 权限只跟 owner 走
SELECT format('ALTER MATERIALIZED VIEW reporting.mv_room_daily_usage OWNER TO %I', :'app_user') \gexec
SELECT format('GRANT SELECT ON reporting.mv_room_daily_usage TO %I', :'app_user') \gexec
SELECT format('GRANT SELECT ON reporting.mv_room_daily_usage TO %I', :'reader_user') \gexec

SELECT format('GRANT SELECT, INSERT, UPDATE ON reporting.report_state TO %I', :'app_user') \gexec
SELECT format('GRANT SELECT ON reporting.report_state TO %I', :'reader_user') \gexec

-- 默认权限：以后新增的表/序列/函数自动授权，不用每次补 GRANT
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA roomdesk GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'app_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA roomdesk GRANT USAGE, SELECT ON SEQUENCES TO %I', :'app_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA roomdesk GRANT EXECUTE ON FUNCTIONS TO %I', :'app_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA roomdesk GRANT SELECT ON TABLES TO %I', :'reader_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA reporting GRANT SELECT ON TABLES TO %I', :'reader_user') \gexec
