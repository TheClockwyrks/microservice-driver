//! Tests for the push of an adversarial run's controller to the backend
//! (`push_controller_to_backend`).
//!
//! These pin the behaviour the arena depends on: a backend-driven run's controller
//! wasm is POSTed to the backend at `/runs/{id}/controller.wasm`, read from the
//! produced `implementation/` tree the driver still holds on disk, and nothing else
//! the run produced is sent to the backend, since the run's tree on the artifacts
//! service holds it. A run with no controller (or whose module is absent) makes no
//! request at all.

use std::sync::Arc;
use std::sync::Mutex;

use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use crate::metrics::*;
use crate::run_record::*;
use crate::validation::*;

use super::push_controller_to_backend;

/// One upload the stub backend received: its request path and body byte length.
#[derive(Debug, Clone)]
struct Upload {
    path: String,
    body_len: usize,
    /// The request's `Authorization` header value, when it carried one.
    authorization: Option<String>,
}

/// The per-job token the controller push is expected to present.
const TOKEN: &str = "job-tok-1";

/// A stub backend that records each POST the upload makes and answers `204`. It
/// loops per connection so reqwest's keep-alive reuse of one socket for several
/// uploads is recorded in full. Returns its base URL and the recorded uploads.
async fn stub_backend() -> (String, Arc<Mutex<Vec<Upload>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    let received = Arc::new(Mutex::new(Vec::new()));
    let sink = received.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let sink = sink.clone();
            tokio::spawn(async move {
                while let Some(upload) = read_request(&mut socket).await {
                    sink.lock().expect("lock").push(upload);
                    if socket
                        .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
                        .await
                        .is_err()
                    {
                        return;
                    }
                    let _ = socket.flush().await;
                }
            });
        }
    });
    (format!("http://{addr}"), received)
}

/// Read one HTTP request from `socket`, returning its path and body length, or
/// `None` at end of stream. Drains the full `Content-Length` body so the next
/// keep-alive request on the same socket starts at a request boundary.
async fn read_request(socket: &mut tokio::net::TcpStream) -> Option<Upload> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let header_end = loop {
        let n = socket.read(&mut chunk).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(pos) = find_subslice(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let request_line = head.lines().next()?;
    let path = request_line.split_whitespace().nth(1)?.to_string();
    let content_length = head
        .lines()
        .find_map(|line| {
            let lower = line.to_ascii_lowercase();
            lower
                .strip_prefix("content-length:")
                .map(|v| v.trim().parse::<usize>().unwrap_or(0))
        })
        .unwrap_or(0);
    let authorization = head.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("authorization")
            .then(|| value.trim().to_string())
    });
    while buf.len() < header_end + content_length {
        let n = socket.read(&mut chunk).await.ok()?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    Some(Upload {
        path,
        body_len: content_length,
        authorization,
    })
}

/// Every upload presents the driver's per-job token: nothing reaches the backend
/// without an identity.
fn assert_every_upload_presents_the_job_token(uploads: &[Upload]) {
    for upload in uploads {
        assert_eq!(
            upload.authorization.as_deref(),
            Some(format!("Bearer {TOKEN}").as_str()),
            "{} presents the per-job token",
            upload.path,
        );
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

/// A produced run record with the given adversarial result (or none).
pub(super) fn record(adversarial: Option<AdversarialResult>) -> RunRecord {
    RunRecord {
        id: "run-1".into(),
        started_at: "2026-06-14T10:00:00Z".into(),
        finished_at: "2026-06-14T10:05:00Z".into(),
        subject: RunSubject {
            test_case_slug: "adversarial-pacman".into(),
            test_case_version: "v1.0.0".into(),
            test_type: crate::test_case::TestType::Adversarial,
            variant: "base".into(),
            harness_slug: HarnessSlug::Claude,
            harness_version: None,
            orchestrator_slug: "one-shot".into(),
            engine_slug: "none".into(),
            engine_version: None,
            model_id: "anthropic/claude-opus-4".into(),
            gg_capability_set: None,
            gg_summary: None,
        },
        tooling: RunTooling {
            test_cabinet_commit: None,
        },
        environment: RunEnvironment {
            os: "linux".into(),
            container_image: "img".into(),
            node_version: None,
            auth_mode: AuthMode::ApiKey,
        },
        metrics: RunMetrics {
            run_time_seconds: 1.0,
            tokens: TokenCounts {
                uncached_input: Some(0),
                cached_input: Some(0),
                output: Some(0),
                reasoning: Some(0),
            },
            cost: Cost {
                comparable: Some(0.0),
                actual: Some(0.0),
            },
            ..RunMetrics::default()
        },
        validation: ValidationSummary {
            debug_scripts: Vec::new(),
            adversarial,
            ..Default::default()
        },
        links: RunLinks::default(),
        status: RunStatus {
            state: RunState::Completed,
            detail: None,
        },
        game_jam_readme: None,
        tool_calls: Default::default(),
        game_jam_prior_entries: Vec::new(),
        seed_commit: None,
        code_analysis: None,
        toolchain: None,
        showcase: None,
    }
}

fn replay_entry(opponent: &str, file: &str) -> AdversarialReplay {
    AdversarialReplay {
        opponent: opponent.into(),
        replay_json: file.into(),
        winner: Some(AdversarialTeam::Red),
        red_score: 20,
        blue_score: 0,
        ended: "swept".into(),
        ticks: 100,
        outcome: AdversarialOutcome::Win,
        scored: true,
    }
}

/// Write `bytes` to `{out_dir}/run-1/implementation/{rel}`.
fn write_impl_file(out_dir: &std::path::Path, rel: &str, bytes: &[u8]) {
    let path = out_dir.join("run-1").join("implementation").join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

/// An adversarial result whose controller module is `controller_module`, with one
/// replay per entry of `replays`.
fn adversarial(controller_module: &str, replays: Vec<AdversarialReplay>) -> AdversarialResult {
    AdversarialResult {
        replay_json: "replay.json".into(),
        opponent: "border-soldier".into(),
        submission_team: AdversarialTeam::Red,
        winner: Some(AdversarialTeam::Red),
        red_score: 20,
        blue_score: 0,
        ended: "swept".into(),
        ticks: 100,
        outcome: AdversarialOutcome::Win,
        detail: None,
        controller_module: controller_module.into(),
        replays,
    }
}

#[tokio::test]
async fn pushes_the_controller_and_nothing_else_to_the_backend() {
    let (backend_url, received) = stub_backend().await;
    let out = TempDir::new().unwrap();

    write_impl_file(out.path(), "replay.json", b"{\"v\":1}");
    write_impl_file(out.path(), "replay-1.json", b"{\"v\":1,\"x\":2}");
    write_impl_file(out.path(), "build/controller.wasm", b"\0asm-bytes");

    let rec = record(Some(adversarial(
        "build/controller.wasm",
        vec![
            replay_entry("border-soldier", "replay.json"),
            replay_entry("greedy-raider", "replay-1.json"),
        ],
    )));

    push_controller_to_backend(&backend_url, TOKEN, &rec, out.path())
        .await
        .expect("the push succeeds");

    let uploads = received.lock().unwrap().clone();
    assert_every_upload_presents_the_job_token(&uploads);
    let paths: Vec<&str> = uploads.iter().map(|u| u.path.as_str()).collect();
    // The proof replays are served from the run's tree on the artifacts service, so
    // the controller is the one file the backend is handed.
    assert_eq!(paths, ["/runs/run-1/controller.wasm"]);
    // The controller upload carries the on-disk wasm bytes verbatim.
    assert_eq!(uploads[0].body_len, b"\0asm-bytes".len());
}

#[tokio::test]
async fn non_adversarial_run_pushes_nothing() {
    let (backend_url, received) = stub_backend().await;
    let out = TempDir::new().unwrap();

    push_controller_to_backend(&backend_url, TOKEN, &record(None), out.path())
        .await
        .expect("no-op succeeds");

    assert!(
        received.lock().unwrap().is_empty(),
        "a non-adversarial run makes no backend upload",
    );
}

#[tokio::test]
async fn a_forfeit_with_no_controller_module_pushes_nothing() {
    let (backend_url, received) = stub_backend().await;
    let out = TempDir::new().unwrap();

    // A forfeit-before-load records an empty module path.
    let rec = record(Some(adversarial(
        "",
        vec![replay_entry("border-soldier", "replay.json")],
    )));

    push_controller_to_backend(&backend_url, TOKEN, &rec, out.path())
        .await
        .expect("no-op succeeds");

    assert!(
        received.lock().unwrap().is_empty(),
        "a run with no controller makes no backend upload",
    );
}

#[tokio::test]
async fn a_controller_missing_on_disk_is_skipped_without_failing() {
    let (backend_url, received) = stub_backend().await;
    let out = TempDir::new().unwrap();

    // The record names a controller, but it was never written to disk (a partial
    // tree). The missing file is skipped, not an error.
    let rec = record(Some(adversarial(
        "build/controller.wasm",
        vec![replay_entry("border-soldier", "replay.json")],
    )));

    push_controller_to_backend(&backend_url, TOKEN, &rec, out.path())
        .await
        .expect("a missing controller is skipped, not fatal");

    assert!(
        received.lock().unwrap().is_empty(),
        "nothing on disk means nothing to upload",
    );
}
