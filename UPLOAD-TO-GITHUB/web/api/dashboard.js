// GET /api/dashboard?from=YYYY-MM-DD&to=YYYY-MM-DD&sample=1
// Returns finished per-source numbers. The browser never sees a key.
import { rpc, isDate } from './_lib.js';

export default async function handler(req, res) {
  const { from, to, sample } = req.query || {};
  if (!isDate(from) || !isDate(to) || from > to || (new Date(to) - new Date(from)) / 864e5 > 400) {
    return res.status(400).json({ error: 'Use from/to as YYYY-MM-DD, at most 400 days apart.' });
  }
  try {
    const data = await rpc('ge_dashboard', { from, to, include_sample: sample !== '0' });
    res.setHeader('Cache-Control', 's-maxage=30, stale-while-revalidate=120');
    return res.status(200).json(data);
  } catch (e) {
    console.error(e);
    return res.status(500).json({ error: 'Could not load the numbers right now.' });
  }
}
