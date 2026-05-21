# Backend API

## Demand and prioritization

Clients call this whenever an episode detail/transcript screen needs shared artifacts:

```http
POST /episodes/:episodeID/artifact-requests
Content-Type: application/json

{ "transcript": true, "chapters": true, "fingerprint": false }
```

The backend stores no user identity. It increments:

- per-episode artifact counters in `artifact_requests`
- per-podcast aggregate demand in `podcast_demands`

Worker jobs are assigned a priority from both signals. That means one transcript request creates work for that episode, while repeated transcript requests across the same podcast make future missing work from that podcast bubble above cold podcasts.

## Worker claim

```http
POST /worker/jobs/claim
Content-Type: application/json

{ "workerID": "mac-mini" }
```

Returns the highest-priority pending job. The priority order is demand-driven and anonymous.

## Queue monitor

```http
GET /queue
```

Browser-friendly HTML dashboard for the worker queue. It shows pending, claimed, completed, and failed job counts, plus the stale-claim watchdog threshold used by the backend's reaper.

The same page is also available at `GET /worker/queue`.
