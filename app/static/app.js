/* ============================================================
   RoomDesk 前端：零依赖原生 JS（没有构建步骤）
   数据全部来自同一后端的 JSON 接口，见 README 的接口表
   ============================================================ */

const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

const EQUIP_LABEL = {
  projector: '投影仪',
  whiteboard: '白板',
  video_conf: '视频会议',
  speakerphone: '会议电话',
  led_wall: 'LED 大屏',
  stage: '舞台',
};

/* ---------- 基础工具 ---------- */

/** 统一 fetch：非 2xx 抛出带 detail 的 Error（后端把领域异常映射成了 4xx） */
async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) },
    ...opts,
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) {
    let detail = `HTTP ${res.status}`;
    if (data && data.detail) {
      detail = typeof data.detail === 'string' ? data.detail : JSON.stringify(data.detail);
    }
    const err = new Error(detail);
    err.status = res.status;
    throw err;
  }
  return data;
}

const pad = (n) => String(n).padStart(2, '0');

/** 生成 datetime-local 需要的本地时间串 */
function dtLocal(daysFromNow, hour, minute = 0) {
  const d = new Date();
  d.setDate(d.getDate() + daysFromNow);
  d.setHours(hour, minute, 0, 0);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** datetime-local 的值 → ISO8601（浏览器按本地时区换算，后端是 timestamptz） */
const toIso = (v) => new Date(v).toISOString();

const fmt = (ts) => new Date(ts).toLocaleString('zh-CN', { hour12: false });
const fmtShort = (ts) => {
  const d = new Date(ts);
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
};
const esc = (s) => String(s ?? '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;');

function toast(el, msg, kind) {
  el.className = `toast show ${kind}`;
  el.innerHTML = msg;
}
function clearToast(el) { el.className = 'toast'; el.innerHTML = ''; }

function statusBadge(s) {
  return s === 'confirmed'
    ? '<span class="badge ok">已确认</span>'
    : '<span class="badge off">已取消</span>';
}

/* ============================================================
   顶栏健康状态
   ============================================================ */
async function loadHealth() {
  const dot = $('#healthDot');
  const txt = $('#healthText');
  try {
    const h = await api('/health');
    dot.className = 'dot ok';
    txt.textContent = `${h.db_user} · ${h.database} · PG ${h.server_version} · ${h.connections} 连接`;
  } catch (e) {
    dot.className = 'dot bad';
    txt.textContent = `数据库不可用：${e.message}`;
  }
}

/* ============================================================
   总览
   ============================================================ */
let roomsCache = [];
let staffCache = [];

async function loadOverview() {
  try {
    const s = await api('/api/ops/stats');
    $('#ov-rooms').textContent = `${s.rooms}`;
    $('#ov-staff').textContent = `${s.staff}`;
    $('#ov-bookings').textContent = `${s.bookings}`;
    $('#ov-fresh-m').textContent = `已确认 ${s.bookings_confirmed} · 已取消 ${s.bookings_cancelled} · 事件 ${s.events}`;
  } catch (e) {
    $('#ov-rooms').textContent = '–';
    $('#ov-fresh-m').textContent = e.message;
  }

  try {
    const rep = await api('/api/reports/utilization?days=7');
    const f = (rep.freshness && rep.freshness[0]) || null;
    $('#ov-fresh').textContent = f ? `${Math.round(f.age_seconds)}s 前` : '—';
    $('#ov-fresh-m').textContent = f ? `${rep.source} · ${f.row_count} 行 · by ${f.last_source}` : '物化视图';
  } catch {
    $('#ov-fresh').textContent = '—';
  }

  await loadRecentBookings();
}

async function loadRecentBookings() {
  const box = $('#ov-recent');
  try {
    const data = await api('/api/bookings?limit=8');
    if (!data.items.length) { box.innerHTML = '<div class="empty">还没有预约。</div>'; return; }
    box.innerHTML = tableBookings(data.items, false);
  } catch (e) {
    box.innerHTML = `<div class="empty">加载失败：${esc(e.message)}</div>`;
  }
}

function tableBookings(items, withCancel) {
  const rows = items.map((b) => `
    <tr>
      <td class="num">${b.id}</td>
      <td>${esc(b.room_name)}</td>
      <td>${esc(b.staff_name)}</td>
      <td class="mono">${esc(fmtShort(b.starts_at))} → ${esc(fmtShort(b.ends_at))}</td>
      <td>${esc(b.purpose || '—')}</td>
      <td>${statusBadge(b.status)}</td>
      <td>${withCancel && b.status === 'confirmed'
        ? `<button class="btn small danger" data-cancel="${b.id}">取消</button>` : ''}</td>
    </tr>`).join('');
  return `<table>
    <thead><tr><th class="num">#</th><th>房间</th><th>人员</th><th>时段</th><th>用途</th><th>状态</th><th></th></tr></thead>
    <tbody>${rows}</tbody></table>`;
}

/* ============================================================
   找空房
   ============================================================ */
async function loadRoomsAndStaff() {
  const [rooms, staff] = await Promise.all([api('/api/rooms'), api('/api/staff')]);
  roomsCache = rooms;
  staffCache = staff;

  // 房间下拉
  $('#book-room').innerHTML = rooms
    .map((r) => `<option value="${r.id}">${esc(r.name)} · ${r.capacity}人</option>`).join('');
  // 人员下拉
  $('#book-staff').innerHTML = staff
    .map((s) => `<option value="${s.id}">${esc(s.name)}（${esc(s.email)}）</option>`).join('');

  // 设备筛选 chip（所有房间设备的并集）
  const all = new Set();
  rooms.forEach((r) => (r.equipment || []).forEach((e) => all.add(e)));
  $('#find-equip').innerHTML = Array.from(all).sort().map((e) => `
    <label class="chip"><input type="checkbox" value="${esc(e)}"> ${esc(EQUIP_LABEL[e] || e)}</label>`).join('');
  $$('#find-equip .chip').forEach((chip) => {
    const input = chip.querySelector('input');
    input.addEventListener('change', () => chip.classList.toggle('on', input.checked));
  });
}

async function doFind(ev) {
  ev.preventDefault();
  const box = $('#find-result');
  const t = $('#find-toast');
  clearToast(t);

  const from = $('#find-from').value;
  const to = $('#find-to').value;
  if (!from || !to) { toast(t, '请选择起止时间。', 'err'); return; }
  if (new Date(to) <= new Date(from)) { toast(t, '结束时间必须晚于开始时间。', 'err'); return; }

  const equip = $$('#find-equip input:checked').map((i) => i.value);
  const params = new URLSearchParams({
    from: toIso(from),
    to: toIso(to),
    min_capacity: $('#find-cap').value || '1',
  });
  if (equip.length) params.set('equipment', equip.join(','));

  box.innerHTML = '<div class="empty">查询中…</div>';
  try {
    const rooms = await api(`/api/rooms/available?${params.toString()}`);
    if (!rooms.length) {
      box.innerHTML = '<div class="empty">这个时段没有满足条件的空房。</div>';
      toast(t, '没有可用房间（可能是被占用，或设备/容量不满足）。', 'err');
      return;
    }
    box.innerHTML = `<table>
      <thead><tr><th>房间</th><th class="num">楼层</th><th class="num">容纳</th><th>设备</th><th></th></tr></thead>
      <tbody>${rooms.map((r) => `
        <tr>
          <td>${esc(r.name)}</td>
          <td class="num">${r.floor}</td>
          <td class="num">${r.capacity}</td>
          <td>${(r.equipment || []).map((e) => esc(EQUIP_LABEL[e] || e)).join('、') || '—'}</td>
          <td><button class="btn small" data-pick="${r.id}">订它</button></td>
        </tr>`).join('')}
      </tbody></table>`;
    toast(t, `找到 <b>${rooms.length}</b> 个可用房间。`, 'ok');

    // 「订它」：把房间和时段带到预约表单
    $$('#find-result [data-pick]').forEach((btn) => {
      btn.addEventListener('click', () => {
        $('#book-room').value = btn.dataset.pick;
        $('#book-from').value = from;
        $('#book-to').value = to;
        switchView('book');
        clearToast($('#book-toast'));
        $('#book-toast').className = 'toast show ok';
        $('#book-toast').innerHTML = '已把房间与时段填好，补充用途后提交即可。';
      });
    });
  } catch (e) {
    box.innerHTML = `<div class="empty">查询失败：${esc(e.message)}</div>`;
    toast(t, esc(e.message), 'err');
  }
}

/* ============================================================
   预约
   ============================================================ */
async function doBook(ev) {
  ev.preventDefault();
  const t = $('#book-toast');
  clearToast(t);

  const body = {
    room_id: Number($('#book-room').value),
    staff_id: Number($('#book-staff').value),
    starts_at: toIso($('#book-from').value),
    ends_at: toIso($('#book-to').value),
    purpose: $('#book-purpose').value.trim(),
    tags: $('#book-tags').value.split(',').map((s) => s.trim()).filter(Boolean),
  };

  try {
    const b = await api('/api/bookings', { method: 'POST', body: JSON.stringify(body) });
    toast(t, `预约成功：#${b.id} ${esc(b.room_name)} ${esc(fmtShort(b.starts_at))} → ${esc(fmtShort(b.ends_at))}`, 'ok');
    await refreshBookingList();
    await loadOverview();
  } catch (e) {
    // 409 的 detail 来自数据库的排他约束，这里原样展示，正好是教学点
    const extra = e.status === 409
      ? '<br><span class="mono" style="font-size:12px">由 PostgreSQL 的 EXCLUDE 约束拦下，应用层没有判重代码。</span>'
      : '';
    toast(t, `失败（HTTP ${e.status}）：${esc(e.message)}${extra}`, 'err');
  }
}

async function refreshBookingList() {
  const box = $('#book-list');
  const q = $('#list-q').value.trim();
  const st = $('#list-status').value;
  const params = new URLSearchParams({ limit: '50' });
  if (q) params.set('q', q);
  if (st) params.set('status', st);

  box.innerHTML = '<div class="empty">加载中…</div>';
  try {
    const data = await api(`/api/bookings?${params.toString()}`);
    if (!data.items.length) { box.innerHTML = '<div class="empty">没有匹配的预约。</div>'; return; }
    box.innerHTML = tableBookings(data.items, true);
    $$('#book-list [data-cancel]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        btn.disabled = true;
        try {
          await api(`/api/bookings/${btn.dataset.cancel}/cancel`, { method: 'POST' });
          await refreshBookingList();
          await loadOverview();
        } catch (e) {
          btn.disabled = false;
          alert(`取消失败：${e.message}`);
        }
      });
    });
  } catch (e) {
    box.innerHTML = `<div class="empty">加载失败：${esc(e.message)}</div>`;
  }
}

/* ============================================================
   报表
   ============================================================ */
async function loadReports() {
  const days = $('#report-days').value || '30';
  const util = $('#report-util');
  util.innerHTML = '<div class="empty">加载中…</div>';

  try {
    const rep = await api(`/api/reports/utilization?days=${days}`);
    const f = (rep.freshness && rep.freshness[0]) || null;
    $('#report-fresh').innerHTML = f
      ? `数据源 <b class="mono">${esc(rep.source)}</b> ·
         刷新于 <b>${esc(fmt(f.refreshed_at))}</b>（${Math.round(f.age_seconds)}s 前）·
         <b>${f.row_count}</b> 行 · 来源 <b>${esc(f.last_source)}</b>
         <span style="color:var(--ink-3)">（读数滞后最多 REFRESH_INTERVAL 秒）</span>`
      : '—';

    if (!rep.items.length) {
      util.innerHTML = '<div class="empty">这个时间窗内没有数据。</div>';
    } else {
      const max = Math.max(...rep.items.map((i) => i.total_hours));
      util.innerHTML = `<table>
        <thead><tr><th class="num">排名</th><th>房间</th><th class="num">次数</th><th class="num">总时长(h)</th>
        <th class="num">平均(h)</th><th class="num">最长(h)</th><th class="num">占比</th>
        <th class="num">累计(h)</th><th style="width:22%">对比</th></tr></thead>
        <tbody>${rep.items.map((i) => `
          <tr>
            <td class="num">${i.rank_by_hours}</td>
            <td>${esc(i.room_name)}</td>
            <td class="num">${i.booking_count}</td>
            <td class="num">${i.total_hours}</td>
            <td class="num">${i.avg_hours ?? '—'}</td>
            <td class="num">${i.max_hours ?? '—'}</td>
            <td class="num">${i.share_pct}%</td>
            <td class="num">${i.running_hours}</td>
            <td><div class="bar"><span style="width:${Math.round((i.total_hours / max) * 100)}%"></span></div></td>
          </tr>`).join('')}
        </tbody></table>`;
    }
  } catch (e) {
    util.innerHTML = `<div class="empty">加载失败：${esc(e.message)}</div>`;
  }

  // 峰值小时
  const peak = $('#report-peak');
  try {
    const rep = await api(`/api/reports/peak-hours?days=7`);
    const max = Math.max(1, ...rep.items.map((i) => i.bookings));
    peak.innerHTML = `<div class="chart">${rep.items.map((i) => `
      <div class="col" title="${i.hour}:00 · ${i.bookings} 次 · ${i.hours_booked}h">
        <div class="v">${i.bookings || ''}</div>
        <div class="b" style="height:${Math.round((i.bookings / max) * 100)}%"></div>
        <div class="h">${i.hour}</div>
      </div>`).join('')}</div>
      <p class="hint" style="margin:10px 0 0">横轴小时，纵轴预约次数；数值来自 <code class="mono">GET /api/reports/peak-hours</code>（实时聚合）。</p>`;
  } catch (e) {
    peak.innerHTML = `<div class="empty">加载失败：${esc(e.message)}</div>`;
  }
}

async function refreshMatview() {
  const t = $('#report-toast');
  const token = $('#admin-token').value.trim();
  clearToast(t);
  try {
    const r = await api('/api/ops/refresh', {
      method: 'POST',
      headers: { 'X-Admin-Token': token },
    });
    toast(t, `读模型已刷新：${r.row_count} 行，${esc(fmt(r.refreshed_at))}`, 'ok');
    await loadReports();
  } catch (e) {
    toast(t, `刷新失败（HTTP ${e.status}）：${esc(e.message)}`, 'err');
  }
}

/* ============================================================
   事件 / 运维
   ============================================================ */
let opsTimer = null;

async function loadOps() {
  // 通知
  try {
    const rows = await api('/api/ops/notifications?limit=20');
    const box = $('#ops-notify');
    if (!rows.length) {
      box.innerHTML = '<div class="empty">还没有事件。去「预约」页新建一条试试（worker 在跑的话几秒内就会出现）。</div>';
    } else {
      box.innerHTML = `<table>
        <thead><tr><th class="num">#</th><th>事件</th><th>payload</th><th>收到时间</th></tr></thead>
        <tbody>${rows.map((r) => `
          <tr>
            <td class="num">${r.id}</td>
            <td class="mono">${esc(r.event)}</td>
            <td class="mono" style="font-size:12px;word-break:break-all">${esc(JSON.stringify(r.payload))}</td>
            <td>${esc(fmt(r.received_at))}</td>
          </tr>`).join('')}
        </tbody></table>`;
    }
  } catch (e) {
    $('#ops-notify').innerHTML = `<div class="empty">加载失败：${esc(e.message)}</div>`;
  }

  // 分区
  try {
    const parts = await api('/api/ops/partitions');
    $('#ops-partitions').innerHTML = `<table>
      <thead><tr><th>分区</th><th class="num">行数</th></tr></thead>
      <tbody>${parts.map((p) => `<tr><td class="mono">${esc(p.partition)}</td><td class="num">${p.rows}</td></tr>`).join('')}
      </tbody></table>`;
  } catch (e) {
    $('#ops-partitions').innerHTML = `<div class="empty">加载失败：${esc(e.message)}</div>`;
  }

  // 数据库自检
  try {
    const d = await api('/api/ops/db');
    $('#ops-identity').innerHTML =
      `当前角色 <b class="mono">${esc(d.identity.db_user)}</b> ·
       PostgreSQL <b>${esc(d.identity.version)}</b> ·
       连接状态 ${d.activity.map((a) => `<b>${esc(a.state)}</b> ${a.connections}`).join(' · ')}`;

    $('#ops-statements').innerHTML = `<table>
      <thead><tr><th class="num">调用</th><th class="num">平均(ms)</th><th class="num">总(ms)</th><th>SQL</th></tr></thead>
      <tbody>${d.top_statements.map((s) => `
        <tr><td class="num">${s.calls}</td><td class="num">${s.mean_ms}</td><td class="num">${s.total_ms}</td>
        <td class="mono" style="font-size:12px;word-break:break-all">${esc(s.query)}</td></tr>`).join('')}
      </tbody></table>`;

    $('#ops-relations').innerHTML = `<table>
      <thead><tr><th>schema</th><th>对象</th><th>类型</th><th class="num">体积</th></tr></thead>
      <tbody>${d.relations.map((r) => `
        <tr><td class="mono">${esc(r.schema)}</td><td class="mono">${esc(r.name)}</td>
        <td>${esc(r.kind)}</td><td class="num">${esc(r.size)}</td></tr>`).join('')}
      </tbody></table>`;
  } catch (e) {
    $('#ops-identity').innerHTML = `<span style="color:var(--bad)">加载失败：${esc(e.message)}</span>`;
  }
}

function startOpsTimer() {
  stopOpsTimer();
  if (!$('#ops-auto').checked) return;
  opsTimer = setInterval(loadOps, 5000);
}
function stopOpsTimer() {
  if (opsTimer) { clearInterval(opsTimer); opsTimer = null; }
}

/* ============================================================
   视图切换 & 初始化
   ============================================================ */
const loaded = new Set();

function switchView(name) {
  $$('#tabs .tab').forEach((t) => t.classList.toggle('active', t.dataset.view === name));
  $$('.view').forEach((v) => v.classList.toggle('active', v.id === `view-${name}`));

  if (name === 'ops') startOpsTimer(); else stopOpsTimer();

  if (loaded.has(name)) return;
  loaded.add(name);

  if (name === 'overview') loadOverview();
  if (name === 'find') loadRoomsAndStaff();
  if (name === 'book') refreshBookingList();
  if (name === 'report') loadReports();
  if (name === 'ops') loadOps();
}

async function init() {
  // 默认时间：明天 10:00 ~ 11:00
  const from = dtLocal(1, 10);
  const to = dtLocal(1, 11);
  $('#find-from').value = from; $('#find-to').value = to;
  $('#book-from').value = from; $('#book-to').value = to;

  $$('#tabs .tab').forEach((tab) => tab.addEventListener('click', () => switchView(tab.dataset.view)));

  $('#find-form').addEventListener('submit', doFind);
  $('#book-form').addEventListener('submit', doBook);
  $('#list-form').addEventListener('submit', (e) => { e.preventDefault(); refreshBookingList(); });
  $('#report-form').addEventListener('submit', (e) => { e.preventDefault(); loadReports(); });
  $('#btn-refresh-mv').addEventListener('click', refreshMatview);
  $('#ops-form').addEventListener('submit', (e) => { e.preventDefault(); loadOps(); });
  $('#ops-auto').addEventListener('change', (e) => {
    $('#ops-auto-chip').classList.toggle('on', e.target.checked);
    startOpsTimer();
  });

  await loadHealth();
  await loadOverview();
  await loadRoomsAndStaff();

  setInterval(loadHealth, 10000);
}

document.addEventListener('DOMContentLoaded', init);
