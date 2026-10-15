"""Background jobs (scan, downloads, list look-ups, sync) the page follows by polling."""
import itertools
import threading
import time
import traceback

_ids = itertools.count(1)


class Job:
    def __init__(self, kind, title):
        self.id = next(_ids)
        self.kind, self.title = kind, title
        self.status = "running"
        self.progress = 0.0
        self.message = ""
        self.lines = []
        self.result = None
        self.error = None
        self.started = time.time()
        self.ended = None
        self.cancelled = False

    def update(self, progress=None, message=None):
        if progress is not None:
            self.progress = max(0.0, min(1.0, float(progress)))
        if message is not None:
            self.message = message

    def log(self, line):
        self.lines.append(line)
        del self.lines[:-300]

    def public(self):
        return {"id": self.id, "kind": self.kind, "title": self.title, "status": self.status,
                "progress": self.progress, "message": self.message, "lines": self.lines[-50:],
                "result": self.result, "error": self.error, "started": self.started,
                "ended": self.ended}


class Jobs:
    def __init__(self):
        self.jobs = {}
        self.lock = threading.Lock()

    def start(self, kind, title, fn):
        job = Job(kind, title)
        with self.lock:
            self.jobs[job.id] = job
            old = sorted((j for j in self.jobs.values() if j.status != "running"), key=lambda j: j.id)[:-30]
            for j in old:
                self.jobs.pop(j.id, None)

        def run():
            try:
                job.result = fn(job)
                job.status = "cancelled" if job.cancelled else "done"
                job.progress = 1.0
            except Exception as e:
                job.error = str(e) or e.__class__.__name__
                job.status = "error"
                job.log(traceback.format_exc(limit=3))
            job.ended = time.time()

        threading.Thread(target=run, daemon=True, name="job-%d" % job.id).start()
        return job

    def get(self, job_id):
        return self.jobs.get(int(job_id))

    def running(self, kind):
        return any(j.kind == kind and j.status == "running" for j in self.jobs.values())

    def public(self):
        return [j.public() for j in sorted(self.jobs.values(), key=lambda j: -j.id)]
