-- 0004 · free_rooms()：把区间重叠判断下推到 SQL
-- 参数用 integer 不用 smallint：psycopg 小整数按 int2 发送，psql 字面量是 int4，只有 integer 两边都匹配

CREATE OR REPLACE FUNCTION free_rooms(
    p_from         timestamptz,
    p_to           timestamptz,
    p_min_capacity integer DEFAULT 1,
    p_equipment    text[]  DEFAULT NULL
)
RETURNS TABLE (
    id        bigint,
    name      text,
    floor     smallint,
    capacity  smallint,
    equipment jsonb,
    active    boolean
)
LANGUAGE sql
STABLE
SET search_path = roomdesk, public
AS $$
    SELECT r.id, r.name, r.floor, r.capacity, r.equipment, r.active
    FROM rooms r
    WHERE r.active
      AND r.capacity >= p_min_capacity
      AND (p_equipment IS NULL OR r.equipment ?& p_equipment)
      AND NOT EXISTS (
            SELECT 1 FROM bookings b
            WHERE b.room_id = r.id
              AND b.status  = 'confirmed'
              AND b.period && tstzrange(p_from, p_to, '[)')
      )
    ORDER BY r.capacity, r.name;
$$;

COMMENT ON FUNCTION free_rooms IS '查某时段可用的房间；区间重叠判断交给 GiST 索引';
