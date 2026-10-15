/* BEGIN e5-hotspotdata (the hotspotdata app, /etc/e5-infoscreen/plugins/hotspotdata) */
// The dark screen's status poll (POLL_BLANK, 5 s: quick to see a new SMS) is
// stretched to what the hotspotdata app's GET /blank-poll says -- only while
// it has the hotspot and the radio off, when no SMS can come.  Asked at most
// once a minute; 5 s again without the app.  A key that lights the screen
// polls at once (setBlank), so nothing old is shown.
let hotspotdataPoll = null, hotspotdataPollAt = -Infinity;
function hotspotdataBlankPoll() {
	if (performance.now() - hotspotdataPollAt > 60000) {
		hotspotdataPollAt = performance.now();
		fetch('/api/plugins/hotspotdata/blank-poll', { cache: 'no-store' })
			.then((r) => r.ok ? r.json() : null)
			.then((r) => { hotspotdataPoll = r && r.ms > POLL_BLANK ? r.ms : null; })
			.catch(() => { hotspotdataPoll = null; });
	}
	return hotspotdataPoll || POLL_BLANK;
}
/* END e5-hotspotdata */
