const fs = require('fs');
const path = require('path');

const pairing = process.argv[2] || 'A70878';
const outDir = path.join(process.cwd(), 'output');

function fmt(dt) {
  const y = dt.getUTCFullYear();
  const m = String(dt.getUTCMonth() + 1).padStart(2, '0');
  const d = String(dt.getUTCDate()).padStart(2, '0');
  const hh = String(dt.getUTCHours()).padStart(2, '0');
  const mm = String(dt.getUTCMinutes()).padStart(2, '0');
  return `${y}-${m}-${d} ${hh}:${mm}`;
}

function parseToken(token) {
  // Examples: (WE08)17:27, (18)23:32
  const m = String(token || '').match(/^\((?:([A-Z]{2})(\d{2})|(\d{2}))\)(\d{2}):(\d{2})$/);
  if (!m) return null;
  const dow = m[1] || null;
  const localHour = Number(m[2] || m[3]);
  const zHour = Number(m[4]);
  const minute = Number(m[5]);
  return { dow, localHour, zHour, minute, raw: token };
}

function normalizeOffset(zHour, localHour) {
  // UTC - local in hours, normalized to common timezone range.
  let offset = zHour - localHour;
  while (offset > 14) offset -= 24;
  while (offset < -12) offset += 24;
  return offset;
}

function inferUtcForToken(baseUtc, token, lowerBoundUtc, upperBoundUtc) {
  if (!token) return null;
  const t = parseToken(token);
  if (!t) return null;

  const candidates = [];
  for (let d = -1; d <= 4; d += 1) {
    const c = new Date(baseUtc);
    c.setUTCDate(c.getUTCDate() + d);
    c.setUTCHours(t.zHour, t.minute, 0, 0);
    if (lowerBoundUtc && c < lowerBoundUtc) continue;
    if (upperBoundUtc && c > upperBoundUtc) continue;
    candidates.push(c);
  }

  if (!candidates.length) return null;

  // choose closest candidate at/after baseUtc when possible
  const after = candidates.filter((c) => c >= baseUtc);
  if (after.length) return after.sort((a, b) => a - b)[0];
  return candidates.sort((a, b) => Math.abs(a - baseUtc) - Math.abs(b - baseUtc))[0];
}

function toCsv(rows) {
  if (!rows.length) return '';
  const headers = Object.keys(rows[0]);
  const esc = (v) => {
    const s = v == null ? '' : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [headers.join(','), ...rows.map((r) => headers.map((h) => esc(r[h])).join(','))].join('\n');
}

async function loadTripBoard() {
  const state = JSON.parse(fs.readFileSync('storageState.json', 'utf8'));
  const cookies = (state.cookies || [])
    .filter((c) => /bidproplus\.com$/.test(c.domain.replace(/^\./, '')))
    .map((c) => `${c.name}=${c.value}`)
    .join('; ');

  const res = await fetch('https://tripboard.bidproplus.com/api/1.0/TripBoard/Load', {
    headers: {
      Cookie: cookies,
      Accept: 'application/json, text/plain, */*',
      Referer: 'https://tripboard.bidproplus.com/',
      'User-Agent': 'Mozilla/5.0',
    },
  });

  if (!res.ok) throw new Error(`TripBoard/Load failed: ${res.status}`);
  return res.json();
}

async function main() {
  const data = await loadTripBoard();

  let trip = null;
  let payPeriod = null;
  for (const pp of (data.payPeriods || [])) {
    const hit = (pp.scheduledTrips || []).find((t) => String(t.pairingNumber).trim() === pairing)
      || (pp.trips || []).find((t) => String(t.pairingNumber).trim() === pairing);
    if (hit) {
      trip = hit;
      payPeriod = pp;
      break;
    }
  }
  if (!trip) throw new Error(`Pairing ${pairing} not found`);

  const legs = (trip.tripDetails?.tripDuties || []).flatMap((d) => d.tripLegs || []);
  const tripEndUtc = new Date(trip.endsOn);

  const rows = legs.map((l, i) => {
    const depBaseUtc = new Date(l.startsOn);
    const nextDepUtc = legs[i + 1] ? new Date(legs[i + 1].startsOn) : tripEndUtc;

    const depToken = parseToken(l.startTime);
    const arrToken = parseToken(l.endTime);

    const depUtc = inferUtcForToken(depBaseUtc, l.startTime, new Date(depBaseUtc.getTime() - 12 * 3600 * 1000), new Date(depBaseUtc.getTime() + 12 * 3600 * 1000)) || depBaseUtc;

    const arrUtc = inferUtcForToken(
      depUtc,
      l.endTime,
      new Date(depUtc.getTime() - 1 * 3600 * 1000),
      new Date(nextDepUtc.getTime() + 48 * 3600 * 1000)
    );

    const depOffset = depToken ? normalizeOffset(depToken.zHour, depToken.localHour) : null;
    const arrOffset = arrToken ? normalizeOffset(arrToken.zHour, arrToken.localHour) : null;

    const depLocal = depOffset == null ? null : new Date(depUtc.getTime() - depOffset * 3600 * 1000);
    const arrLocal = arrUtc && arrOffset != null ? new Date(arrUtc.getTime() - arrOffset * 3600 * 1000) : null;

    return {
      leg: i + 1,
      flight: l.flightNumber || '',
      dep_airport: l.origin || '',
      dep_local: depLocal ? fmt(depLocal) : '',
      arr_airport: l.destination || '',
      arr_local: arrLocal ? fmt(arrLocal) : '',
      status: String(l.status || '').trim() || '-',
      block: l.block || '',
      dep_token: l.startTime || '',
      arr_token: l.endTime || '',
      dep_utc_source: fmt(depUtc),
      arr_utc_source: arrUtc ? fmt(arrUtc) : '',
      dep_utc_minus_local_hours: depOffset == null ? '' : depOffset,
      arr_utc_minus_local_hours: arrOffset == null ? '' : arrOffset,
    };
  });

  const raw = String(payPeriod.payPeriodId || '0000').replace(/\D/g, '');
  const label = raw.length >= 4 ? `PP${raw.slice(0, 2)}-${raw.slice(-2)}` : `PP00-${raw.padStart(2, '0')}`;

  const outJson = path.join(outDir, `${label}_${pairing}_Legs_Local.json`);
  const outCsv = path.join(outDir, `${label}_${pairing}_Legs_Local.csv`);

  fs.writeFileSync(outJson, JSON.stringify({ pairing: trip.pairingNumber, title: trip.title, route: (trip.plainSubTitle || '').trim(), rows }, null, 2));
  fs.writeFileSync(outCsv, toCsv(rows));

  console.log(`Wrote ${outJson}`);
  console.log(`Wrote ${outCsv}`);
  console.log(JSON.stringify(rows, null, 2));
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
