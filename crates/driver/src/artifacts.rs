//! Uploading the produced run tree to the artifact service.
//!
//! A driver pod is ephemeral: the run tree it writes to its scratch `out_dir`
//! (`run-record.json`, the collected `implementation/` with the playable build and
//! proof/asset media, and the `events.jsonl`/`raw.jsonl` logs) is lost when the pod
//! exits. So when an artifact service is configured (`TCAB_ARTIFACTS_URL`), the
//! driver tars `{out_dir}/{id}/` and uploads it to
//! `POST {artifacts_url}/runs/{id}/artifacts`, authed by the **same per-job token**
//! it streams status to the backend with — the artifact service forwards that token
//! to the backend to verify. Because that token was minted for the **job id** (a
//! different UUID from the run/record id in the upload path, which is the store
//! key), the driver sends its job id in the `x-tcab-job-id` header so the service
//! verifies against the right job. The upload happens after the held `storing`
//! report and *before* the terminal status is posted (see
//! [`finish`](crate::finish)), so by the time the console sees the run finish its
//! artifacts are already servable.
//!
//! The driver's copy is the only one until the service acknowledges it, and the pod
//! is discarded afterwards. So a failed upload is sorted into one of two
//! [kinds](UploadFailureKind): a failure that is this run's own ends the upload at
//! once, and every other failure is a condition of the store, which the driver
//! [waits on](retry_until_stored) under the finishing [retry
//! policy](crate::retry::RetryPolicy), holding the tree and telling the backend
//! through a [`StoreWait`] that it is doing so: [`RunWait`] repeats the run's
//! `storing` report after each failed attempt, with the failure as its reason.
//! Whether the tree landed, and whether the store was the reason it did not, is
//! part of the run's terminal report ([`store_run_tree`], [`TreeStore`]); it never
//! changes the run's own outcome. See the driver overview's "Artifacts" and
//! "Retries".
//!
//! When `TCAB_ARTIFACTS_URL` is unset (a local setup), nothing here runs — there
//! is no separate artifact service in that topology.

use std::fs::File;
use std::future::Future;
use std::io::Seek;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use crate::client::{JobClient, StoreFields};
use crate::retry::{FinalFailure, RetryEnd, RetryPolicy};
use crate::{RunRecord, find_build_output};
use test_cabinet_backend_client::{BackendClient, HttpBackendClient};

/// How much of the tarball one chunk of the upload body carries.
const TARBALL_CHUNK: usize = 256 * 1024;

/// How long one repeated `storing` report may take. The report tells the backend
/// why the run is still storing; the wait it describes goes on whether or not it
/// lands.
const WAIT_REPORT_TIMEOUT: Duration = Duration::from_secs(30);

/// The policy a run-tree upload is retried under: the one policy every call of a
/// run's finishing shares ([`RetryPolicy`]), bounded by
/// `TCAB_ARTIFACT_UPLOAD_WAIT_SECONDS`, with its
/// [`stall_limit`](RetryPolicy::stall_limit) ending an attempt that makes no
/// progress.
pub type UploadRetry = RetryPolicy;

/// A failure tarring or uploading the produced run tree.
#[derive(Debug, thiserror::Error)]
pub enum UploadError {
    /// The run directory could not be read or tarred.
    #[error("tarring the run tree at `{path}`: {source}")]
    Tar {
        /// The run directory that could not be archived.
        path: String,
        /// The underlying I/O error.
        #[source]
        source: std::io::Error,
    },
    /// The upload request could not be sent (a transport/connection error).
    #[error("uploading artifacts to the artifact service: {0}")]
    Transport(#[source] reqwest::Error),
    /// The artifact service rejected the upload with a non-success status.
    #[error("the artifact service rejected the upload: HTTP {status}{}", body_suffix(.body))]
    Status {
        /// The HTTP status the service returned.
        status: reqwest::StatusCode,
        /// The response body, for diagnostics.
        body: String,
    },
    /// The upload stopped making progress: no part of the tree was taken, and no
    /// answer arrived, for the whole of the stall limit.
    #[error("the upload to the artifact service stalled for {} s", .0.as_secs())]
    Stalled(Duration),
}

/// Append the body to a status error when there is one to show.
fn body_suffix(body: &str) -> String {
    if body.trim().is_empty() {
        String::new()
    } else {
        format!(": {}", body.trim())
    }
}

/// Whose failure a failed upload is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UploadFailureKind {
    /// This run's own: something about its tree that no state of the store would
    /// change. The upload ends at once.
    RunsOwn,
    /// A condition of the store, or of the path to it: the tree is sound and would
    /// land on a store that could take it. The driver waits on it.
    StoreCondition,
}

impl UploadError {
    /// Whose failure this is.
    ///
    /// Four failures are provably about this one tree: it could not be tarred, the
    /// service refused it as over its size cap (`413`), the service refused a path
    /// in it (`400`), or the service could not read it as an archive (`422`).
    /// Sending the same bytes again gets the same answer whatever the store does.
    ///
    /// Everything else is a store condition: no answer, a stall, a `5xx` (a full or
    /// faulted volume among them), a `401` or `403` (the service could not verify
    /// the job token), a `404`, and any status nothing here expects. None of them
    /// says the tree is at fault, so none of them is a reason to discard the only
    /// copy of it.
    pub fn kind(&self) -> UploadFailureKind {
        match self {
            Self::Tar { .. } => UploadFailureKind::RunsOwn,
            Self::Status { status, .. }
                if *status == reqwest::StatusCode::PAYLOAD_TOO_LARGE
                    || *status == reqwest::StatusCode::BAD_REQUEST
                    || *status == reqwest::StatusCode::UNPROCESSABLE_ENTITY =>
            {
                UploadFailureKind::RunsOwn
            }
            Self::Transport(_) | Self::Stalled(_) | Self::Status { .. } => {
                UploadFailureKind::StoreCondition
            }
        }
    }
}

impl FinalFailure for UploadError {
    fn is_final(&self) -> bool {
        self.kind() == UploadFailureKind::RunsOwn
    }
}

/// What a driver waiting on the store tells, and asks of, its surroundings.
///
/// The wait is the one stretch of a run's finishing in which the driver holds the
/// only copy of something nothing can reproduce while a different service is at
/// fault. So the backend is told about it, which keeps the job reading `storing`
/// and the console showing the run as waiting to store its files, and an
/// operator's cancellation has to be able to end it.
pub trait StoreWait {
    /// Whether the run was canceled before its upload began. Asked once, ahead of
    /// the first attempt. Such an upload is the one a canceled gg run was wound down
    /// to make, so the cancellation behind it must not end it; it waits at most
    /// [`CANCELED_RUN_UPLOAD_WAIT`](crate::retry::CANCELED_RUN_UPLOAD_WAIT) instead.
    fn already_canceled(&self) -> impl Future<Output = bool> + Send;

    /// The latest attempt failed on a store condition for `reason`, and another
    /// follows. Called once per such failed attempt, before the wait that precedes
    /// the next one.
    fn waiting(&self, reason: &str) -> impl Future<Output = ()> + Send;

    /// Resolves when the run has been canceled. Raced against the whole upload,
    /// the first attempt included, unless the run was
    /// [already canceled](Self::already_canceled).
    fn canceled(&self) -> impl Future<Output = ()> + Send;
}

/// A wait nobody is told about and nothing cancels: for a caller with no job to
/// report against.
#[derive(Debug, Clone, Copy, Default)]
pub struct Unattended;

impl StoreWait for Unattended {
    async fn already_canceled(&self) -> bool {
        false
    }
    async fn waiting(&self, _reason: &str) {}
    async fn canceled(&self) {
        std::future::pending().await
    }
}

/// A run's wait on the artifact store, reported to the backend through the run's
/// own [`JobClient`].
///
/// The held report has already handed the backend the run's record before any
/// upload begins (the driver overview's "Finishing a run"). Each report of the
/// wait repeats it: a `storing` status carrying the same record and the run's own
/// failure detail, so the backend's held copy is replaced with an identical one,
/// plus the upload's latest failure as `storeFault`.
#[derive(Debug)]
pub struct RunWait<'a> {
    client: &'a JobClient,
    record: RunRecord,
    run_failure: Option<String>,
}

impl<'a> RunWait<'a> {
    /// The wait of a run that produced `record`. `run_failure` is the reason the
    /// run failed when the driver will report it `failed`, and `None` otherwise:
    /// the same detail the held report carried.
    pub fn holding(client: &'a JobClient, record: &RunRecord, run_failure: Option<&str>) -> Self {
        Self {
            client,
            record: record.clone(),
            run_failure: run_failure.map(str::to_string),
        }
    }
}

impl StoreWait for RunWait<'_> {
    async fn already_canceled(&self) -> bool {
        crate::retry::is_canceled(self.client).await
    }

    async fn waiting(&self, reason: &str) {
        let report = self.client.post_status_storing(
            &self.record,
            self.run_failure.as_deref(),
            Some(reason),
        );
        match tokio::time::timeout(WAIT_REPORT_TIMEOUT, report).await {
            Ok(Ok(())) => {}
            Ok(Err(err)) => {
                tracing::warn!(
                    run_id = %self.record.id,
                    error = %err,
                    "could not repeat the storing report while waiting on the artifact store"
                );
            }
            Err(_) => {
                tracing::warn!(
                    run_id = %self.record.id,
                    "repeating the storing report while waiting on the artifact store timed out"
                );
            }
        }
    }

    async fn canceled(&self) {
        crate::retry::job_canceled(self.client).await
    }
}

/// How an upload that did not store the tree ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UploadEnd {
    /// An attempt failed as the [run's own](UploadFailureKind::RunsOwn).
    RunsOwn,
    /// The store did not take the tree within the policy's
    /// [wait](RetryPolicy::give_up_after).
    GaveUp,
    /// The run was canceled while its tree was being uploaded.
    Canceled,
}

/// An upload that ended without the tree stored.
#[derive(Debug)]
pub struct UploadFailure {
    /// How the upload ended.
    pub end: UploadEnd,
    /// The last attempt's failure. `None` only for an upload canceled before any
    /// attempt had failed.
    pub error: Option<UploadError>,
}

impl std::fmt::Display for UploadFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.error {
            Some(error) => error.fmt(f),
            None => f.write_str("the run was canceled before its tree was uploaded"),
        }
    }
}

impl std::error::Error for UploadFailure {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.error
            .as_ref()
            .map(|error| error as &(dyn std::error::Error + 'static))
    }
}

impl UploadFailure {
    /// Why the tree was not stored, when the cause was a condition of the store:
    /// the last failure of an upload the driver gave up on, or was canceled out
    /// of after an attempt had failed on one. `None` when the failure was the
    /// run's own, and for a cancellation that no failed attempt preceded.
    pub fn store_fault(&self) -> Option<String> {
        match (self.end, &self.error) {
            (UploadEnd::GaveUp | UploadEnd::Canceled, Some(error))
                if error.kind() == UploadFailureKind::StoreCondition =>
            {
                Some(error.to_string())
            }
            _ => None,
        }
    }

    /// A failure of the run's own that ended the upload before any attempt.
    fn runs_own(error: UploadError) -> Self {
        Self {
            end: UploadEnd::RunsOwn,
            error: Some(error),
        }
    }
}

/// Make `attempt` until it succeeds, waiting on a store that cannot take the tree.
///
/// The retry loop is the finishing one ([`retry_call_reporting`](crate::retry::retry_call_reporting)):
/// a failure that is the [run's own](UploadFailureKind::RunsOwn) ends the upload
/// at once, on any attempt; every other failure is retried after the policy's
/// delay until the policy's wait has passed since the first failure, telling
/// `wait` of each failed attempt another follows.
///
/// A cancellation ends the upload wherever it lands: mid-attempt, mid-report or
/// mid-sleep. The exception is a run that was
/// [already canceled](StoreWait::already_canceled) when its upload began. A
/// canceled gg run uploads its tree after the cancellation, and that upload must
/// not be cut short by the very cancellation it follows. It is retried like any
/// other, for at most
/// [`CANCELED_RUN_UPLOAD_WAIT`](crate::retry::CANCELED_RUN_UPLOAD_WAIT)
/// ([`RetryPolicy::for_canceled_run`]).
///
/// Split from [`upload_run_tree_with`] so the wait runs against scripted attempts
/// on a paused clock.
pub async fn retry_until_stored<W, A, F>(
    policy: &UploadRetry,
    wait: &W,
    run_id: &str,
    attempt: A,
) -> Result<(), UploadFailure>
where
    W: StoreWait,
    A: FnMut() -> F,
    F: Future<Output = Result<(), UploadError>>,
{
    let already_canceled = wait.already_canceled().await;
    let policy = if already_canceled {
        policy.clone().for_canceled_run()
    } else {
        policy.clone()
    };
    let canceled = async {
        if already_canceled {
            std::future::pending().await
        } else {
            wait.canceled().await
        }
    };
    let what = format!("the run tree upload of run {run_id}");
    crate::retry::retry_call_reporting(&policy, &what, canceled, attempt, |error| {
        let reason = error.to_string();
        async move { wait.waiting(&reason).await }
    })
    .await
    .map_err(|failure| UploadFailure {
        end: match failure.end {
            RetryEnd::Refused => UploadEnd::RunsOwn,
            RetryEnd::GaveUp => UploadEnd::GaveUp,
            RetryEnd::Canceled => UploadEnd::Canceled,
        },
        error: failure.error,
    })
}

/// Tar the run tree at `{out_dir}/{run_id}/` and upload it to the artifact service
/// at `artifacts_url`, presenting `job_token`, in a single attempt nobody is told
/// about. See [`upload_run_tree_with`].
pub async fn upload_run_tree(
    artifacts_url: &str,
    run_id: &str,
    job_id: &str,
    out_dir: &Path,
    job_token: &str,
) -> Result<(), UploadFailure> {
    upload_run_tree_with(
        &UploadRetry::single_attempt(),
        &Unattended,
        artifacts_url,
        run_id,
        job_id,
        out_dir,
        job_token,
    )
    .await
}

/// Tar the run tree at `{out_dir}/{run_id}/` and upload it to the artifact service
/// at `artifacts_url`, presenting `job_token`. The tarball's entries are relative
/// to the run directory (so the service unpacks them under its own
/// `<store-root>/{run_id}/`), matching the layout the engine's resolvers read.
///
/// `run_id` is the **run/record id** — the store key the upload URL carries and the
/// console later addresses media by. `job_id` is the **job id** the per-job token
/// was minted for; the service verifies the token against it (a different UUID from
/// the run id), so it is sent in the `x-tcab-job-id` header rather than the path.
///
/// The tree is tarred once and the tarball kept on disk for every attempt, each of
/// which reads it from its first byte; [`retry_until_stored`] makes the attempts
/// under `policy`, reporting to `wait`. Returns `Ok` once the service has
/// acknowledged the upload (`2xx`).
pub async fn upload_run_tree_with<W: StoreWait>(
    policy: &UploadRetry,
    wait: &W,
    artifacts_url: &str,
    run_id: &str,
    job_id: &str,
    out_dir: &Path,
    job_token: &str,
) -> Result<(), UploadFailure> {
    let run_dir = out_dir.join(run_id);
    let path_label = run_dir.display().to_string();

    // Build the tarball on DISK and stream it, rather than assembling it in memory.
    //
    // This is the driver's single largest allocation and the reason its memory
    // footprint used to be unsizeable. A run tree is bounded only by the case that
    // produced it — source, a static build, and proof/asset media — so buffering the
    // whole archive made peak driver memory a function of the heaviest case rather
    // than of the driver's own work: measured peaks ran ~475MiB against a 512Mi
    // request, i.e. right at what the node had reserved. Every other moment in a
    // driver's life costs under 10MiB.
    //
    // The timing is what makes that dangerous rather than merely untidy. This upload
    // happens AFTER the harness session has finished and BEFORE the terminal status
    // is posted, so a driver killed here loses a run that has already paid for every
    // one of its API calls — strictly the most expensive way for a run to die. Reading
    // the archive off disk a chunk at a time makes the driver's footprint a property
    // of the driver instead of the case, which is what lets its memory request be a
    // real reservation (see the dispatcher's `DEFAULT_DRIVER_MEMORY_REQUEST`; the
    // driver carries no memory limit, deliberately).
    //
    // Tarring is a blocking filesystem walk, so it runs on the blocking pool: the same
    // task is still streaming harness events and heartbeating status, and stalling the
    // reactor for the length of a large walk would starve both.
    let scratch_dir = out_dir.to_path_buf();
    let tarball = tokio::task::spawn_blocking(move || tar_run_dir(&run_dir, &scratch_dir))
        .await
        .map_err(|join| {
            UploadFailure::runs_own(UploadError::Tar {
                path: path_label.clone(),
                source: std::io::Error::other(join),
            })
        })?
        .map_err(|source| {
            UploadFailure::runs_own(UploadError::Tar {
                path: path_label.clone(),
                source,
            })
        })?;

    // One client for every attempt. The connect timeout bounds an attempt against a
    // service that is not there; there is deliberately no overall timeout, because
    // the body is as large as the run tree and a slow link is not a failure. An
    // attempt that stops moving is ended by the policy's stall limit.
    let http = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .build()
        .map_err(|err| UploadFailure::runs_own(UploadError::Transport(err)))?;
    let url = format!("{artifacts_url}/runs/{run_id}/artifacts");
    let tarball = Arc::new(tarball);
    let stall_limit = policy.stall_limit;

    // Each attempt reads the same archive from its start, at offsets of its own. An
    // earlier attempt's body can outlive its `send` when the service answers before
    // it has read the whole of it (a full volume does exactly that), and a cursor
    // shared with it would be moved under this one.
    retry_until_stored(policy, wait, run_id, || {
        send_tarball(
            &http,
            &url,
            job_id,
            job_token,
            Arc::clone(&tarball),
            stall_limit,
        )
    })
    .await
}

/// Send one attempt of the run-tree upload: the whole of `tarball` as the body of
/// `POST {url}`, abandoned as [stalled](UploadError::Stalled) when it makes no
/// progress for `stall_limit`.
async fn send_tarball(
    http: &reqwest::Client,
    url: &str,
    job_id: &str,
    job_token: &str,
    tarball: Arc<File>,
    stall_limit: Duration,
) -> Result<(), UploadError> {
    // No `Content-Length`: a wrapped stream has no size hint, so reqwest frames the
    // body `chunked`. The artifact service's `DefaultBodyLimit` enforces its cap as
    // the bytes arrive either way, and declaring a length alongside a chunked body
    // would be the one framing error that could truncate an upload silently.
    let progress = Arc::new(AtomicU64::new(0));
    let body = reqwest::Body::wrap_stream(tarball_chunks(tarball, Arc::clone(&progress)));
    let attempt = async {
        let response = http
            .post(url)
            .bearer_auth(job_token)
            .header("x-tcab-job-id", job_id)
            .header(reqwest::header::CONTENT_TYPE, "application/x-tar")
            .body(body)
            .send()
            .await
            .map_err(UploadError::Transport)?;
        let status = response.status();
        if status.is_success() {
            return Ok(());
        }
        let body = response.text().await.unwrap_or_default();
        Err(UploadError::Status { status, body })
    };
    tokio::select! {
        result = attempt => result,
        () = crate::retry::stalled(&progress, stall_limit) => Err(UploadError::Stalled(stall_limit)),
    }
}

/// The tarball as a stream of chunks, read from its first byte at explicit
/// offsets. Each chunk the connection takes is counted in `progress`.
///
/// The connection asks for a chunk only when it has room to send one, so the count
/// moves exactly as fast as the service reads. Reading at an offset leaves the
/// file's own cursor alone, so any number of these streams over one file are
/// independent.
fn tarball_chunks(
    tarball: Arc<File>,
    progress: Arc<AtomicU64>,
) -> impl futures_util::Stream<Item = std::io::Result<Vec<u8>>> + Send + 'static {
    futures_util::stream::try_unfold(0u64, move |offset| {
        let tarball = Arc::clone(&tarball);
        let progress = Arc::clone(&progress);
        async move {
            // A blocking read, so it runs on the blocking pool like the tar walk.
            let chunk = tokio::task::spawn_blocking(move || read_chunk_at(&tarball, offset))
                .await
                .map_err(std::io::Error::other)??;
            if chunk.is_empty() {
                return Ok(None);
            }
            progress.fetch_add(1, Ordering::Relaxed);
            let next = offset + chunk.len() as u64;
            Ok(Some((chunk, next)))
        }
    })
}

/// Read up to [`TARBALL_CHUNK`] bytes of `file` at `offset`. Empty at its end.
fn read_chunk_at(file: &File, offset: u64) -> std::io::Result<Vec<u8>> {
    let mut chunk = vec![0u8; TARBALL_CHUNK];
    #[cfg(unix)]
    let read = std::os::unix::fs::FileExt::read_at(file, &mut chunk, offset)?;
    #[cfg(windows)]
    let read = std::os::windows::fs::FileExt::seek_read(file, &mut chunk, offset)?;
    chunk.truncate(read);
    Ok(chunk)
}

/// What became of a run's tree: what [`store_run_tree`] returns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TreeStore {
    /// No artifact service is configured, so nothing was uploaded.
    NoService,
    /// The service acknowledged the tree.
    Stored,
    /// The upload ended without the tree stored.
    NotStored {
        /// How the upload ended.
        end: UploadEnd,
        /// The upload's last failure, when it was a condition of the store rather
        /// than the run's own ([`UploadFailure::store_fault`]).
        store_fault: Option<String>,
    },
}

impl TreeStore {
    /// What the terminal status report carries as `artifactsStored`: absent with no
    /// artifact service, else whether the tree landed.
    pub fn artifacts_stored(&self) -> Option<bool> {
        match self {
            Self::NoService => None,
            Self::Stored => Some(true),
            Self::NotStored { .. } => Some(false),
        }
    }

    /// What the terminal status report carries as `storeFault`: why the tree was
    /// not stored, when the store was the cause.
    pub fn store_fault(&self) -> Option<&str> {
        match self {
            Self::NotStored { store_fault, .. } => store_fault.as_deref(),
            Self::NoService | Self::Stored => None,
        }
    }

    /// Both fields as the terminal report takes them.
    pub fn store_fields(&self) -> StoreFields {
        StoreFields {
            artifacts_stored: self.artifacts_stored(),
            store_fault: self.store_fault().map(str::to_string),
        }
    }

    /// Whether the run was canceled while its tree was being uploaded. The job is
    /// then terminally `canceled`, and `canceled` is the only status the backend
    /// still takes for it.
    pub fn canceled_during_upload(&self) -> bool {
        matches!(
            self,
            Self::NotStored {
                end: UploadEnd::Canceled,
                ..
            }
        )
    }

    /// Whether the run's terminal report is `canceled` rather than the outcome the
    /// run reached: the run itself was canceled (`run_canceled`), or its upload
    /// was. Either way the job is terminally `canceled`, and a `succeeded` or
    /// `failed` report would be discarded with the record it carries.
    pub fn reports_canceled(&self, run_canceled: bool) -> bool {
        run_canceled || self.canceled_during_upload()
    }
}

/// Upload the produced run tree to the artifact service and, once the service has
/// acknowledged it, stamp the run's playable-build link onto `record`.
///
/// - [`TreeStore::NoService`] when `artifacts_url` is `None` (a local setup with no
///   artifact service): nothing is uploaded and the record carries no playable link.
/// - [`TreeStore::Stored`] when the tree landed. The link is set root-relative
///   (`/runs/{id}/build/`), and only when the run produced a static build to serve.
/// - [`TreeStore::NotStored`] when the upload ended without it: the failure was the
///   run's own, the store did not take the tree for the whole of `policy`'s wait,
///   or the run was canceled during the upload. The failure is logged at `error`
///   with the service's last status and body, and the link is left off the record:
///   a link nothing serves would offer a build that is not there.
///
/// A tree that is not stored never changes the run's outcome. The record still
/// reaches the backend with the state the run reached; what is lost is the tree,
/// and the backend is told so through `artifactsStored`.
pub async fn store_run_tree<W: StoreWait>(
    policy: &UploadRetry,
    wait: &W,
    artifacts_url: Option<&str>,
    record: &mut RunRecord,
    job_id: &str,
    out_dir: &Path,
    job_token: &str,
) -> TreeStore {
    let Some(artifacts_url) = artifacts_url else {
        return TreeStore::NoService;
    };
    match upload_run_tree_with(
        policy,
        wait,
        artifacts_url,
        &record.id,
        job_id,
        out_dir,
        job_token,
    )
    .await
    {
        Ok(()) => {
            if let Some(link) = playable_build_link(out_dir, &record.id) {
                record.links.playable_build = Some(link);
            }
            tracing::info!(run_id = %record.id, "uploaded run artifacts to the artifact service");
            TreeStore::Stored
        }
        Err(failure) => {
            let (status, body) = match &failure.error {
                Some(UploadError::Status { status, body }) => (Some(status.as_u16()), body.trim()),
                Some(
                    UploadError::Tar { .. } | UploadError::Transport(_) | UploadError::Stalled(_),
                )
                | None => (None, ""),
            };
            tracing::error!(
                run_id = %record.id,
                status,
                body,
                end = ?failure.end,
                error = %failure,
                "could not store the run's artifact tree; the run is reported with its \
                 own outcome, but it has no tree to play or publish"
            );
            TreeStore::NotStored {
                end: failure.end,
                store_fault: failure.store_fault(),
            }
        }
    }
}

/// Push an adversarial run's controller wasm to the backend, keyed by run id, so the
/// arena can pit the run from any host.
///
/// The backend keeps a pushed run's `controller.wasm` in its database beside the run's
/// row (`POST /runs/{id}/controller.wasm`), and the arena lists a run's controller as
/// pittable only when the backend holds it (`GET /adversarial/controllers`). Everything
/// else the run produced, its proof replays included, is served from the run's tree on
/// the artifacts service, so the controller is the one file the driver hands the
/// backend.
///
/// Best-effort and driven purely off the produced record: a no-op for a
/// non-adversarial run, and for a forfeit-before-load that emitted no controller. The
/// module is read from the produced tree the driver still holds at
/// `{out_dir}/{id}/implementation/`; a missing file is skipped, and a rejected upload
/// is surfaced so the caller can log it. The client presents the per-job `job_token`
/// (see the auth overview's "In-cluster callers").
pub async fn push_controller_to_backend(
    backend_url: &str,
    job_token: &str,
    record: &RunRecord,
    out_dir: &Path,
) -> crate::Result<()> {
    let Some(adversarial) = record.validation.adversarial.as_ref() else {
        return Ok(());
    };
    // A forfeit-before-load run records an empty module path and has nothing to push.
    if adversarial.controller_module.is_empty() {
        return Ok(());
    }
    let module = out_dir
        .join(&record.id)
        .join("implementation")
        .join(&adversarial.controller_module);
    let Ok(bytes) = std::fs::read(module) else {
        return Ok(());
    };
    HttpBackendClient::new(backend_url)
        .with_token(Some(job_token.to_string()))
        .publish_run_controller(&record.id, bytes)
        .await?;
    Ok(())
}

/// Tar `run_dir` into a temporary file on `scratch_dir`, with every entry path
/// relative to `run_dir` itself (so the archive root *is* the run directory's
/// contents). The whole tree is walked: `run-record.json`, the `implementation/`
/// build/media, and the `events.jsonl`/`raw.jsonl` logs when present. The returned
/// file is rewound, ready for the upload to read from the start.
///
/// `scratch_dir` is the driver's own out-dir rather than the system temp dir, for
/// two reasons: it is the volume already sized to hold a run tree, and it is the
/// same filesystem as `run_dir`, so the archive cannot fail halfway on a `/tmp` that
/// turns out to be a small tmpfs — which, being memory-backed, would also reinstate
/// the very allocation writing to disk exists to avoid.
///
/// The file is created via `tempfile_in`, so it has **no directory entry**: the
/// kernel reclaims it when the last descriptor closes, including when the driver is
/// killed mid-upload. Nothing is left behind for a later run to trip over, and there
/// is no cleanup path that has to be remembered on the error branches.
fn tar_run_dir(run_dir: &Path, scratch_dir: &Path) -> Result<File, std::io::Error> {
    let mut file = tempfile::tempfile_in(scratch_dir)?;
    {
        let mut builder = tar::Builder::new(&mut file);
        // `append_dir_all("", run_dir)` archives the directory's *contents* at the
        // archive root (an empty prefix), which is exactly the relative layout the
        // service untars under `<store-root>/{id}/`.
        builder.append_dir_all("", run_dir)?;
        // Write the end-of-archive trailer before the borrow ends; without it the
        // service sees a truncated tar.
        builder.finish()?;
    }
    // `append_dir_all` left the cursor at the end of the archive.
    file.rewind()?;
    Ok(file)
}

/// The root-relative playable-build link for a produced run, when its collected
/// implementation contains a static build. Mirrors what the worker set at list
/// time (`/runs/{id}/build/`): root-relative, so the console prefixes the artifact
/// service base URL it learned from the backend's `/config`. `None` when the run
/// produced no static build (it has nothing to play).
pub fn playable_build_link(out_dir: &Path, run_id: &str) -> Option<String> {
    let impl_dir = out_dir.join(run_id).join("implementation");
    find_build_output(&impl_dir)
        .is_some()
        .then(|| format!("/runs/{run_id}/build/"))
}

#[cfg(test)]
#[path = "artifacts.test.rs"]
mod tests;

#[cfg(test)]
#[path = "artifacts.tarball.test.rs"]
mod tarball_tests;

#[cfg(test)]
#[path = "artifacts.retry.test.rs"]
mod retry_tests;

#[cfg(test)]
#[path = "artifacts.runwait.test.rs"]
mod runwait_tests;

#[cfg(test)]
#[path = "artifacts.wait.test.rs"]
mod wait_tests;

#[cfg(test)]
#[path = "artifacts.repeated.test.rs"]
mod repeated_tests;
