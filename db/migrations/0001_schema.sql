-- ============================================================
--  0001 · 核心表
--  执行身份：roomdesk_migrator
--  search_path 已在角色上设为 roomdesk, reporting, public
-- ============================================================

-- ---------- 人员 ----------
CREATE TABLE IF NOT EXISTS staff (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text        NOT NULL,
    email      text        NOT NULL,
    role       text        NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'admin')),
    created_at timestamptz NOT NULL DEFAULT now()
);
-- 邮箱大小写不敏感的唯一约束：唯一索引建在表达式上
CREATE UNIQUE INDEX IF NOT EXISTS staff_email_uniq ON staff (lower(email));

COMMENT ON TABLE staff IS '可预约会议室的人';

-- ---------- 房间 ----------
CREATE TABLE IF NOT EXISTS rooms (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name      text     NOT NULL UNIQUE,
    floor     smallint NOT NULL,
    capacity  smallint NOT NULL CHECK (capacity BETWEEN 1 AND 500),
    equipment jsonb    NOT NULL DEFAULT '[]'::jsonb,
    active    boolean  NOT NULL DEFAULT true,
    CONSTRAINT rooms_equipment_is_array CHECK (jsonb_typeof(equipment) = 'array')
);
-- JSONB 数组的存在/包含查询走 GIN
CREATE INDEX IF NOT EXISTS rooms_equipment_gin ON rooms USING gin (equipment jsonb_path_ops);

-- ---------- 预约 ----------
CREATE TABLE IF NOT EXISTS bookings (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_id         bigint      NOT NULL REFERENCES rooms (id),
    staff_id        bigint      NOT NULL REFERENCES staff (id),
    period          tstzrange   NOT NULL,
    purpose         text        NOT NULL DEFAULT '',
    status          text        NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'cancelled')),
    idempotency_key text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    cancelled_at    timestamptz,
    CONSTRAINT bookings_period_not_empty CHECK (NOT isempty(period)),

    -- ▼▼ 核心：同一房间 + 时间段重叠 → 直接失败，且并发安全 ▼▼
    -- 应用层不做「先查后插」，正确性由数据库保证；
    -- WHERE status='confirmed' 让已取消的预约自动退出约束。
    CONSTRAINT bookings_no_overlap EXCLUDE USING gist (
        room_id WITH =,
        period  WITH &&
    ) WHERE (status = 'confirmed')
);

COMMENT ON CONSTRAINT bookings_no_overlap ON bookings IS
    '同一房间时间段重叠禁止；GiST 谓词锁保证并发下也只能成功一个';

-- 幂等键：部分唯一索引（只约束非空值）
CREATE UNIQUE INDEX IF NOT EXISTS bookings_idem_uniq ON bookings (idempotency_key)
    WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS bookings_period_gist ON bookings USING gist (period);
CREATE INDEX IF NOT EXISTS bookings_room_start  ON bookings (room_id, lower(period));
CREATE INDEX IF NOT EXISTS bookings_purpose_trgm ON bookings USING gin (purpose gin_trgm_ops);
