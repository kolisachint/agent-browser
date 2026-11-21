//! Downloads observed on the attached browser, so `wait --download` can
//! claim a download that finished before the command arrived (#561).

use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DownloadState {
    InProgress,
    Completed,
    Canceled,
}

#[derive(Debug, Clone)]
pub struct DownloadRecord {
    pub guid: String,
    pub state: DownloadState,
    /// Where the browser saved the file. Chrome only reports it on the
    /// completed `Browser.downloadProgress` event when `eventsEnabled` is set.
    pub file_path: Option<String>,
    /// Set once any `Browser.*` event arrives for this download. From then on
    /// only `Browser.downloadProgress` finishes it: `Page.downloadProgress`
    /// reports completion first, before the path is known.
    browser_events: bool,
    claimed: bool,
    /// CDP session that reported a `Page.*` event for this download. Page
    /// events arrive on the session attached to the downloading frame, so
    /// this identifies the owning tab; `Browser.*` events are sessionless.
    pub page_session: Option<String>,
    /// Frame that started the download, from either willBegin event. Used to
    /// attribute sessionless `Browser.*` events via a frame-to-session index.
    pub frame_id: Option<String>,
}

/// How many download records the ledger keeps. Sessions sharing one browser
/// all see every download; foreign records are never claimed, so without a
/// cap the ledger would grow for the life of the browser.
const MAX_RECORDS: usize = 512;

/// Downloads in the order they began. Records live as long as the browser
/// instance; `clear` runs whenever a new browser is attached.
#[derive(Debug, Default)]
pub struct DownloadLedger {
    records: Vec<DownloadRecord>,
}

impl DownloadLedger {
    pub fn clear(&mut self) {
        self.records.clear();
    }

    /// Record a download event. `Page.*` and `Browser.*` events for one
    /// download share a guid; only `Browser.downloadProgress` carries the file
    /// path, and only when `eventsEnabled` is set. Provider connections that
    /// never enable it still report completion through `Page.*`.
    /// `session` is the CDP session the event arrived on, if any:
    /// `Browser.*` events are sessionless, while `Page.*` events arrive on
    /// the session attached to the downloading frame and identify the owning
    /// tab. Returns false for any other method.
    pub fn observe(&mut self, method: &str, params: &Value, session: Option<&str>) -> bool {
        let Some(guid) = params.get("guid").and_then(|v| v.as_str()) else {
            return false;
        };
        match method {
            "Browser.downloadWillBegin" | "Page.downloadWillBegin" => {
                let frame_id = params
                    .get("frameId")
                    .and_then(|v| v.as_str())
                    .map(String::from);
                let record = self.record_mut(guid);
                record.browser_events |= method.starts_with("Browser.");
                if method.starts_with("Page.") {
                    record.page_session = session.map(String::from);
                }
                if record.frame_id.is_none() {
                    record.frame_id = frame_id;
                }
                true
            }
            "Browser.downloadProgress" | "Page.downloadProgress" => {
                let state = params.get("state").and_then(|v| v.as_str());
                let file_path = params.get("filePath").and_then(|v| v.as_str());
                let from_browser = method.starts_with("Browser.");
                let record = self.record_mut(guid);
                record.browser_events |= from_browser;
                if method.starts_with("Page.") && record.page_session.is_none() {
                    record.page_session = session.map(String::from);
                }
                if record.browser_events && !from_browser {
                    return true;
                }
                match state {
                    Some("completed") => record.state = DownloadState::Completed,
                    Some("canceled") => record.state = DownloadState::Canceled,
                    _ => {}
                }
                if let Some(path) = file_path {
                    record.file_path = Some(path.to_string());
                }
                true
            }
            _ => false,
        }
    }

    /// Claim the oldest finished download that no earlier wait has claimed.
    pub fn claim_finished(&mut self) -> Option<DownloadRecord> {
        self.claim_finished_where(|_| true)
    }

    /// Claim the oldest finished download owned by this session. A session
    /// sharing one browser with others must not claim their downloads: each
    /// daemon only sees the union of events, so the owner predicate decides
    /// which records this session may take (see `download_is_owned`).
    pub fn claim_finished_where(
        &mut self,
        owned: impl Fn(&DownloadRecord) -> bool,
    ) -> Option<DownloadRecord> {
        let record = self
            .records
            .iter_mut()
            .find(|r| !r.claimed && r.state != DownloadState::InProgress && owned(r))?;
        record.claimed = true;
        Some(record.clone())
    }

    /// Return a claimed download to the queue, for a wait that failed after
    /// claiming it.
    pub fn release(&mut self, guid: &str) {
        if let Some(record) = self.records.iter_mut().find(|r| r.guid == guid) {
            record.claimed = false;
        }
    }

    /// Mark a download as handled elsewhere, so `wait --download` never
    /// claims it. `download <selector> <path>` owns its own file.
    pub fn mark_claimed(&mut self, guid: &str) {
        self.record_mut(guid).claimed = true;
    }

    fn record_mut(&mut self, guid: &str) -> &mut DownloadRecord {
        if let Some(index) = self.records.iter().position(|r| r.guid == guid) {
            return &mut self.records[index];
        }
        if self.records.len() >= MAX_RECORDS {
            // Foreign sessions' finished downloads are never claimed here;
            // drop claimed records first so unclaimed work is never lost.
            if let Some(index) = self.records.iter().position(|r| r.claimed) {
                self.records.remove(index);
            } else {
                self.records.remove(0);
            }
        }
        self.records.push(DownloadRecord {
            guid: guid.to_string(),
            state: DownloadState::InProgress,
            file_path: None,
            browser_events: false,
            claimed: false,
            page_session: None,
            frame_id: None,
        });
        self.records.last_mut().expect("record was just pushed")
    }
}

/// Whether the download reported on `owner_session` belongs to the session
/// bound to `bound_target`. The caller resolves the owner session from the
/// record first: its `page_session`, or the daemon's frame-to-session index
/// for the record's `frame_id` when only sessionless `Browser.*` events
/// arrived. `session_target` resolves one of this daemon's CDP session ids
/// to its target id; every daemon attaches to every tab of a shared browser,
/// so a raw session match cannot tell tabs apart. A download with no
/// attributable target (unknown frame, or an unbound session) is owned: that
/// preserves the single-session behavior and lets a restarted daemon claim a
/// download that began before it learned the frame.
pub fn download_is_owned(
    owner_session: Option<&str>,
    bound_target: Option<&str>,
    session_target: impl Fn(&str) -> Option<String>,
) -> bool {
    let Some(bound) = bound_target else {
        // Legacy sessions track every tab; only pinning draws the boundary.
        return true;
    };
    match owner_session.and_then(&session_target) {
        Some(target) => target == bound,
        None => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn completed(ledger: &mut DownloadLedger, guid: &str, path: &str) {
        ledger.observe("Browser.downloadWillBegin", &json!({ "guid": guid }), None);
        ledger.observe(
            "Browser.downloadProgress",
            &json!({ "guid": guid, "state": "completed", "filePath": path }),
            None,
        );
    }

    #[test]
    fn claims_a_download_that_finished_before_the_wait() {
        let mut ledger = DownloadLedger::default();
        completed(&mut ledger, "a", "/dl/a.bin");
        let record = ledger.claim_finished().expect("finished download");
        assert_eq!(record.file_path.as_deref(), Some("/dl/a.bin"));
        assert!(
            ledger.claim_finished().is_none(),
            "a download is claimed once"
        );
    }

    #[test]
    fn a_released_download_can_be_claimed_again() {
        let mut ledger = DownloadLedger::default();
        completed(&mut ledger, "a", "/dl/a.bin");
        let record = ledger.claim_finished().expect("finished download");
        ledger.release(&record.guid);
        let again = ledger.claim_finished().expect("released download");
        assert_eq!(again.guid, "a");
        assert!(ledger.claim_finished().is_none());
    }

    #[test]
    fn claims_in_the_order_downloads_began() {
        let mut ledger = DownloadLedger::default();
        ledger.observe(
            "Browser.downloadWillBegin",
            &json!({ "guid": "first" }),
            None,
        );
        completed(&mut ledger, "second", "/dl/second.bin");
        ledger.observe(
            "Browser.downloadProgress",
            &json!({ "guid": "first", "state": "completed", "filePath": "/dl/first.bin" }),
            None,
        );
        assert_eq!(ledger.claim_finished().unwrap().guid, "first");
        assert_eq!(ledger.claim_finished().unwrap().guid, "second");
    }

    #[test]
    fn skips_downloads_still_in_progress() {
        let mut ledger = DownloadLedger::default();
        ledger.observe(
            "Browser.downloadWillBegin",
            &json!({ "guid": "slow" }),
            None,
        );
        ledger.observe(
            "Browser.downloadProgress",
            &json!({ "guid": "slow", "state": "inProgress" }),
            None,
        );
        assert!(ledger.claim_finished().is_none());
    }

    #[test]
    fn reports_canceled_downloads() {
        let mut ledger = DownloadLedger::default();
        ledger.observe(
            "Browser.downloadProgress",
            &json!({ "guid": "x", "state": "canceled" }),
            None,
        );
        assert_eq!(
            ledger.claim_finished().unwrap().state,
            DownloadState::Canceled
        );
    }

    #[test]
    fn merges_page_and_browser_events_for_one_download() {
        let mut ledger = DownloadLedger::default();
        ledger.observe(
            "Page.downloadWillBegin",
            &json!({ "guid": "g" }),
            Some("s1"),
        );
        ledger.observe("Browser.downloadWillBegin", &json!({ "guid": "g" }), None);
        ledger.observe(
            "Page.downloadProgress",
            &json!({ "guid": "g", "state": "completed" }),
            Some("s1"),
        );
        ledger.observe(
            "Browser.downloadProgress",
            &json!({ "guid": "g", "state": "completed", "filePath": "/dl/g.bin" }),
            None,
        );
        assert_eq!(
            ledger.claim_finished().unwrap().file_path.as_deref(),
            Some("/dl/g.bin")
        );
        assert!(ledger.claim_finished().is_none());
    }

    #[test]
    fn waits_for_the_browser_event_that_carries_the_path() {
        let mut ledger = DownloadLedger::default();
        ledger.observe(
            "Page.downloadWillBegin",
            &json!({ "guid": "g" }),
            Some("s1"),
        );
        ledger.observe("Browser.downloadWillBegin", &json!({ "guid": "g" }), None);
        ledger.observe(
            "Page.downloadProgress",
            &json!({ "guid": "g", "state": "completed" }),
            Some("s1"),
        );
        assert!(
            ledger.claim_finished().is_none(),
            "Page completion arrives before the path is known"
        );
    }

    #[test]
    fn page_events_alone_finish_a_download_without_a_path() {
        let mut ledger = DownloadLedger::default();
        ledger.observe(
            "Page.downloadWillBegin",
            &json!({ "guid": "p" }),
            Some("s1"),
        );
        ledger.observe(
            "Page.downloadProgress",
            &json!({ "guid": "p", "state": "completed" }),
            Some("s1"),
        );
        let record = ledger.claim_finished().unwrap();
        assert_eq!(record.state, DownloadState::Completed);
        assert_eq!(record.file_path, None);
    }

    #[test]
    fn never_claims_a_download_marked_as_handled() {
        let mut ledger = DownloadLedger::default();
        ledger.mark_claimed("owned");
        completed(&mut ledger, "owned", "/dl/owned.bin");
        assert!(ledger.claim_finished().is_none());
    }

    #[test]
    fn ignores_other_events_and_clears() {
        let mut ledger = DownloadLedger::default();
        assert!(!ledger.observe("Page.frameNavigated", &json!({ "guid": "p" }), Some("s1")));
        completed(&mut ledger, "a", "/dl/a.bin");
        ledger.clear();
        assert!(ledger.claim_finished().is_none());
    }

    #[test]
    fn page_events_record_the_owning_session_and_frame() {
        let mut ledger = DownloadLedger::default();
        ledger.observe(
            "Page.downloadWillBegin",
            &json!({ "guid": "g", "frameId": "F1" }),
            Some("s1"),
        );
        ledger.observe(
            "Browser.downloadWillBegin",
            &json!({ "guid": "g", "frameId": "F1" }),
            None,
        );
        assert!(ledger.claim_finished().is_none(), "still in progress");
        ledger.observe(
            "Browser.downloadProgress",
            &json!({ "guid": "g", "state": "completed", "filePath": "/dl/g.bin" }),
            None,
        );
        let record = ledger.claim_finished().unwrap();
        assert_eq!(record.page_session.as_deref(), Some("s1"));
        assert_eq!(record.frame_id.as_deref(), Some("F1"));
    }

    #[test]
    fn claim_finished_where_skips_foreign_downloads() {
        let mut ledger = DownloadLedger::default();
        completed(&mut ledger, "mine", "/dl/mine.bin");
        completed(&mut ledger, "theirs", "/dl/theirs.bin");
        let foreign = |r: &DownloadRecord| r.guid == "theirs";
        assert_eq!(ledger.claim_finished_where(foreign).unwrap().guid, "theirs");
        assert!(ledger.claim_finished_where(foreign).is_none());
        assert_eq!(ledger.claim_finished().unwrap().guid, "mine");
    }

    #[test]
    fn ownership_follows_the_bound_target() {
        let resolve = |session: &str| match session {
            "s1" => Some("target-a".to_string()),
            "s2" => Some("target-b".to_string()),
            _ => None,
        };
        assert!(download_is_owned(Some("s1"), Some("target-a"), resolve));
        assert!(!download_is_owned(Some("s2"), Some("target-a"), resolve));
        assert!(download_is_owned(Some("s9"), Some("target-a"), resolve));
        assert!(download_is_owned(None, Some("target-a"), resolve));
        assert!(download_is_owned(Some("s2"), None, resolve));
    }

    #[test]
    fn ledger_caps_records_so_foreign_downloads_do_not_accumulate() {
        let mut ledger = DownloadLedger::default();
        for i in 0..(MAX_RECORDS + 10) {
            let guid = format!("g{i}");
            ledger.observe("Browser.downloadWillBegin", &json!({ "guid": guid }), None);
        }
        assert!(ledger.records.len() <= MAX_RECORDS);
        completed(&mut ledger, "claimed", "/dl/claimed.bin");
        assert!(ledger.claim_finished().is_some());
        for i in 0..(MAX_RECORDS + 10) {
            let guid = format!("h{i}");
            ledger.observe("Browser.downloadWillBegin", &json!({ "guid": guid }), None);
        }
        assert!(ledger.records.len() <= MAX_RECORDS);
    }
}
