const fs = require('fs');

const pairing = process.argv[2] || 'A70878';
const state = JSON.parse(fs.readFileSync('storageState.json', 'utf8'));
const cookies = (state.cookies || [])
  .filter(c => /bidproplus\.com$/.test(c.domain.replace(/^\./, '')))
  .map(c => `${c.name}=${c.value}`)
  .join('; ');

function fmtDate(iso) {
  if (!iso) return '';
  const s = String(iso);
  return `${s.slice(0,10)} ${s.slice(11,16)}`;
}

function fmtHHMM(t) {
  const s = String(t || '').padStart(4, '0');
  if (!/^\d{4}$/.test(s)) return '';
  return `${s.slice(0,2)}:${s.slice(2)}`;
}

async function main() {
  const res = await fetch('https://tripboard.bidproplus.com/api/1.0/TripBoard/Load', {
    headers: {
      'Cookie': cookies,
      'Accept': 'application/json, text/plain, */*',
      'Referer': 'https://tripboard.bidproplus.com/',
      'User-Agent': 'Mozilla/5.0'
    }
  });
  if (!res.ok) throw new Error(`TripBoard/Load failed: ${res.status}`);
  const data = await res.json();

  const payPeriods = data.payPeriods || [];
  let trip = null;
  for (const pp of payPeriods) {
    for (const t of (pp.scheduledTrips || [])) {
      if (String(t.pairingNumber).trim() === pairing) {
        trip = t;
        break;
      }
    }
    if (trip) break;
  }
  if (!trip) throw new Error(`Pairing ${pairing} not found in scheduledTrips`);

  const legs = [];
  for (const duty of (trip.tripDetails?.tripDuties || [])) {
    for (const l of (duty.tripLegs || [])) {
      legs.push({
        flight: l.flightNumber || l.flightNum || '',
        dep_airport: l.origin || l.departure || '',
        dep_time: l.startTime ? fmtHHMM(l.startTime) : fmtDate(l.startsOn),
        arr_airport: l.destination || l.arrival || '',
        arr_time: l.endTime ? fmtHHMM(l.endTime) : fmtDate(l.endsOn),
        status: String(l.status || '').trim() || '-'
      });
    }
  }

  console.log(JSON.stringify({
    pairing: trip.pairingNumber,
    title: trip.title,
    route: (trip.plainSubTitle || '').trim(),
    start: fmtDate(trip.startsOn),
    end: fmtDate(trip.endsOn),
    credit: trip.credit,
    legs
  }, null, 2));
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
