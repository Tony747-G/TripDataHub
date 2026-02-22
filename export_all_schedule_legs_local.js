const fs = require('fs');
const path = require('path');

const outputDir = path.join(process.cwd(), 'output');

function fmt(dt) {
  const y = dt.getUTCFullYear();
  const m = String(dt.getUTCMonth() + 1).padStart(2, '0');
  const d = String(dt.getUTCDate()).padStart(2, '0');
  const hh = String(dt.getUTCHours()).padStart(2, '0');
  const mm = String(dt.getUTCMinutes()).padStart(2, '0');
  return `${y}-${m}-${d} ${hh}:${mm}`;
}

function parseToken(token) {
  const m = String(token || '').match(/^\((?:([A-Z]{2})(\d{2})|(\d{2}))\)(\d{2}):(\d{2})$/);
  if (!m) return null;
  const localHour = Number(m[2] || m[3]);
  const zHour = Number(m[4]);
  const minute = Number(m[5]);
  return { localHour, zHour, minute };
}

function normalizeOffset(zHour, localHour) {
  let offset = zHour - localHour;
  while (offset > 14) offset -= 24;
  while (offset < -12) offset += 24;
  return offset;
}

function inferUtcForToken(baseUtc, token, lowerBoundUtc, upperBoundUtc) {
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
  const after = candidates.filter((c) => c >= baseUtc).sort((a, b) => a - b);
  if (after.length) return after[0];
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

function labelFromPayPeriodId(id) {
  const raw = String(id || '').replace(/\D/g, '');
  if (raw.length >= 4) return `PP${raw.slice(0, 2)}-${raw.slice(-2)}`;
  return `PP00-${raw.padStart(2, '0')}`;
}

function formatDuration(minutes) {
  if (minutes == null || Number.isNaN(minutes)) return '';
  const safe = Math.max(0, Math.round(minutes));
  const hh = Math.floor(safe / 60);
  const mm = safe % 60;
  return `${hh}:${String(mm).padStart(2, '0')}`;
}

function calcBlockFromUtc(depUtc, arrUtc) {
  if (!depUtc || !arrUtc) return null;
  let deltaMs = arrUtc.getTime() - depUtc.getTime();
  // Some legs cross date lines and may appear negative with inferred day.
  while (deltaMs < 0) deltaMs += 24 * 3600 * 1000;
  const minutes = deltaMs / (60 * 1000);
  // Keep sane operational range for one leg.
  if (minutes > 24 * 60) return null;
  return minutes;
}

async function loadTripBoard() {
  const state = JSON.parse(fs.readFileSync('storageState.json', 'utf8'));
  const cookies = (state.cookies || [])
    .filter((c) => /bidproplus\.com$/.test(c.domain.replace(/^\./, '')))
    .map((c) => `${c.name}=${c.value}`)
    .join('; ');

  if (!cookies) throw new Error('No bidproplus cookies in storageState.json');

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
  const load = await loadTripBoard();
  const targetLabels = new Set(['PP26-02', 'PP26-03']);
  const manifest = [];

  for (const pp of load.payPeriods || []) {
    const label = labelFromPayPeriodId(pp.payPeriodId);
    if (!targetLabels.has(label)) continue;

    const outRows = [];
    for (const trip of pp.scheduledTrips || []) {
      const rawLegs = (trip.tripDetails?.tripDuties || []).flatMap((d) => d.tripLegs || []);
      const tripEndUtc = new Date(trip.endsOn);

      rawLegs.forEach((l, i) => {
        const depBaseUtc = new Date(l.startsOn);
        const nextDepUtc = rawLegs[i + 1] ? new Date(rawLegs[i + 1].startsOn) : tripEndUtc;

        const depTok = parseToken(l.startTime);
        const arrTok = parseToken(l.endTime);

        const depUtc = inferUtcForToken(
          depBaseUtc,
          l.startTime,
          new Date(depBaseUtc.getTime() - 12 * 3600 * 1000),
          new Date(depBaseUtc.getTime() + 12 * 3600 * 1000)
        ) || depBaseUtc;

        const arrUtc = inferUtcForToken(
          depUtc,
          l.endTime,
          new Date(depUtc.getTime() - 1 * 3600 * 1000),
          new Date(nextDepUtc.getTime() + 48 * 3600 * 1000)
        ) || null;

        const depOffset = depTok ? normalizeOffset(depTok.zHour, depTok.localHour) : null;
        const arrOffset = arrTok ? normalizeOffset(arrTok.zHour, arrTok.localHour) : null;

        const depLocal = depOffset == null ? null : new Date(depUtc.getTime() - depOffset * 3600 * 1000);
        const arrLocal = arrUtc && arrOffset != null ? new Date(arrUtc.getTime() - arrOffset * 3600 * 1000) : null;
        const blockMinutes = calcBlockFromUtc(depUtc, arrUtc);
        const blockCalculated = formatDuration(blockMinutes);

        outRows.push({
          pay_period: label,
          pairing: trip.pairingNumber || '',
          leg: i + 1,
          flight: l.flightNumber || '',
          dep_airport: l.origin || '',
          dep_local: depLocal ? fmt(depLocal) : '',
          arr_airport: l.destination || '',
          arr_local: arrLocal ? fmt(arrLocal) : '',
          status: String(l.status || '').trim() || '-',
          block: blockCalculated || l.block || '',
          block_raw: l.block || '',
        });
      });
    }

    const jsonPath = path.join(outputDir, `${label}_Schedule_Legs.json`);
    const csvPath = path.join(outputDir, `${label}_Schedule_Legs.csv`);

    fs.writeFileSync(jsonPath, JSON.stringify({
      pay_period: label,
      pay_period_id: pp.payPeriodId,
      start_local: String(pp.startsOn).replace('T', ' ').slice(0, 16),
      end_local: String(pp.endsOn).replace('T', ' ').slice(0, 16),
      trip_count: (pp.scheduledTrips || []).length,
      leg_count: outRows.length,
      rows: outRows,
    }, null, 2));

    fs.writeFileSync(csvPath, toCsv(outRows));

    manifest.push({
      label,
      trip_count: (pp.scheduledTrips || []).length,
      leg_count: outRows.length,
      json: path.basename(jsonPath),
      csv: path.basename(csvPath),
    });
  }

  const manifestPath = path.join(outputDir, 'PP_Schedule_Legs_manifest.json');
  fs.writeFileSync(manifestPath, JSON.stringify({ generated_at: new Date().toISOString(), manifest }, null, 2));
  console.log(JSON.stringify({ manifestPath, manifest }, null, 2));
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
