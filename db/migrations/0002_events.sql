-- ============================================================
--  0002 · 事件：分区表 + 审计触发器 + LISTEN/NOTIFY
--
--  同时演示两个 PG 能力：
--    1) 按月 RANGE 分区：审计日志只增不改，天然适合按时间切
--    2) pg_notify：业务写入的同一个事务里发通知，
--       worker 容器 LISTEN 后落库 —— 不会丢事件
-- ============================================================

-- ---------- 事件表（分区） ----------
CREATE TABLE IF NOT EXISTS booking_events (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    booking_id  bigint      NOT NULL,
    event       text        NOT NULL,
    payload     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT booking_events_pk PRIMARY KEY (id, occurred_at)   -- 分区键必须在主键里
) PARTITION BY RANGE (occurred_at);

-- ---------- 分区自动创建 ----------
-- SECURITY DEFINER：让 app 角色也能调用（月度分区维护），
-- 但函数体以 owner（migrator）身份执行，不需要给 app DDL 权限。
CREATE OR REPLACE FUNCTION ensure_month_partition(p_month date)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = roomdesk, public
AS $$
DECLARE
    v_name text := format('booking_events_%s', to_char(p_month, 'YYYY"m"MM'));
    v_from date := date_trunc('month', p_month)::date;
    v_to   date := (date_trunc('month', p_month) + interval '1 month')::date;
BEGIN
    IF to_regclass('roomdesk.' || v_name) IS NOT NULL THEN
        RETURN v_name || ' (exists)';
    END IF;
    -- 注意：DEFAULT 分区里若已有该月数据，这里会失败。
    -- 生产做法是每月提前建下个月分区（见 docs/ARCHITECTURE.md）。
    EXECUTE format(
        'CREATE TABLE roomdesk.%I PARTITION OF roomdesk.booking_events
         FOR VALUES FROM (%L) TO (%L)', v_name, v_from, v_to);
    RETURN v_name || ' (created)';
END $$;

-- 本月 + 下月；其余落 DEFAULT，便于演示「兜底分区」的坑
SELECT ensure_month_partition(date_trunc('month', now())::date);
SELECT ensure_month_partition((date_trunc('month', now()) + interval '1 month')::date);

CREATE TABLE IF NOT EXISTS booking_events_default
    PARTITION OF booking_events DEFAULT;

-- ---------- 审计触发器（事件表） ----------
CREATE OR REPLACE FUNCTION log_booking_event()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO roomdesk.booking_events (booking_id, event, payload)
        VALUES (NEW.id, 'created', jsonb_build_object(
            'room_id', NEW.room_id,
            'staff_id', NEW.staff_id,
            'period', NEW.period::text));
    ELSE
        INSERT INTO roomdesk.booking_events (booking_id, event, payload)
        VALUES (NEW.id,
                CASE WHEN NEW.status IS DISTINCT FROM OLD.status THEN 'status_changed' ELSE 'updated' END,
                jsonb_build_object('old_status', OLD.status,
                                   'new_status', NEW.status,
                                   'old_period', OLD.period::text,
                                   'new_period', NEW.period::text));
    END IF;
    RETURN NULL;
END $$;

-- ---------- 通知触发器（pg_notify） ----------
-- payload 会被 worker 的 LISTEN 收到；同时落 notifications 表做持久化
CREATE OR REPLACE FUNCTION notify_booking_event()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_event   text;
    v_payload jsonb;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_event := 'booking.created';
        v_payload := jsonb_build_object('id', NEW.id, 'room_id', NEW.room_id,
                                        'staff_id', NEW.staff_id, 'period', NEW.period::text);
    ELSE
        v_event := CASE WHEN NEW.status IS DISTINCT FROM OLD.status
                        THEN 'booking.' || NEW.status ELSE 'booking.updated' END;
        v_payload := jsonb_build_object('id', NEW.id, 'room_id', NEW.room_id,
                                        'status', NEW.status);
    END IF;

    PERFORM pg_notify('roomdesk_bookings',
                      jsonb_build_object('event', v_event, 'payload', v_payload)::text);
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS bookings_event_log ON bookings;
CREATE TRIGGER bookings_event_log
    AFTER INSERT OR UPDATE ON bookings
    FOR EACH ROW EXECUTE FUNCTION log_booking_event();

DROP TRIGGER IF EXISTS bookings_notify ON bookings;
CREATE TRIGGER bookings_notify
    AFTER INSERT OR UPDATE ON bookings
    FOR EACH ROW EXECUTE FUNCTION notify_booking_event();

-- ---------- 通知落库表（worker 写入） ----------
CREATE TABLE IF NOT EXISTS notifications (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event       text        NOT NULL,
    payload     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    received_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notifications_recent ON notifications (received_at DESC);
