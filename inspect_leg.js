const fs = require('fs');

const state = JSON.parse(fs.readFileSync('storageState.json', 'utf8'));
const cookies = (state.cookies || [])
  .filter(c => /bidproplus\.com$/.test(c.domain.replace(/^\./, '')))
  .map(c => c.name + '=' + c.value)
  .join('; ');

async function main() {
  const res = await fetch('https://tripboard.bidproplus.com/api/1.0/TripBoard/Load', {
    headers: { Cookie: cookies, Accept: 'application/json, text/plain, */*' }
  });
  const data = await res.json();
  const pp = (data.payPeriods || []).find(p => (p.scheduledTrips || []).some(t => t.pairingNumber === 'A70878'));
  const t = pp.scheduledTrips.find(x => x.pairingNumber === 'A70878');
  const legs = t.tripDetails.tripDuties.flatMap(d => d.tripLegs || []);
  console.log('leg count', legs.length);
  console.log(JSON.stringify(legs[0], null, 2));
}

main().catch(e => { console.error(e.message); process.exit(1); });
