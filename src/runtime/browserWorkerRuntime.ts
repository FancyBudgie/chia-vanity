import type {
    DeriveAddressPayload,
    DeriveAddressRequest,
    SearchCompletedPayload,
    SearchFailedPayload,
    SearchHitPayload,
    SearchProgressPayload,
    SearchStatePayload,
    StartSearchRequest,
    VanityRuntime,
} from './types.ts';
import { RecentRate } from '../lib/recentRate.ts';
import { validateWantedPatterns } from '../lib/vanityValidation.ts';

type EventPayloads = {
    progress: SearchProgressPayload;
    completed: SearchCompletedPayload;
    failed: SearchFailedPayload;
    state: SearchStatePayload;
};

type ListenerMap = {
    [K in keyof EventPayloads]: Array<(payload: EventPayloads[K]) => void>;
};

type WorkerDonePayload = { hit: SearchHitPayload | null };
type SearchWorkerPlan = { engine: 'cpu' | 'gpu'; offset: number };

const MAX_INDEX = 0xffff_ffff;
const recentRate = new RecentRate();
const listeners: ListenerMap = {
    progress: [],
    completed: [],
    failed: [],
    state: [],
};

let running = false;
let startedAt = 0;
let totalChecked = 0;
let workers: Worker[] = [];
let pendingWorkers = 0;
let bestHit: SearchCompletedPayload['hit'] = null;
let cancelView: Int32Array | null = null;
let activeRunId = 0;
let reportedCpuWorkers: number | undefined;

function emit<K extends keyof EventPayloads>(kind: K, payload: EventPayloads[K]) {
    for (const listener of listeners[kind]) listener(payload);
}

function subscribe<K extends keyof EventPayloads>(
    kind: K,
    cb: (payload: EventPayloads[K]) => void,
): Promise<() => void> {
    const bucket = listeners[kind] as Array<(payload: EventPayloads[K]) => void>;
    bucket.push(cb);
    return Promise.resolve(() => {
        const index = bucket.indexOf(cb);
        if (index >= 0) bucket.splice(index, 1);
    });
}

function resetRunState() {
    totalChecked = 0;
    startedAt = performance.now();
    recentRate.reset(startedAt);
    pendingWorkers = 0;
    bestHit = null;
    cancelView = null;
    reportedCpuWorkers = undefined;
}

function createWorker(): Worker {
    return new Worker(new URL('../workers/vanityWorker.ts', import.meta.url), {
        type: 'module',
    });
}

function cleanupWorkers(clearCancelView = true) {
    for (const worker of workers) worker.terminate();
    workers = [];
    if (clearCancelView) cancelView = null;
}

function finish(payload: SearchCompletedPayload) {
    running = false;
    cleanupWorkers();
    emit('state', { running: false });
    emit('completed', payload);
}

function fail(message: string) {
    running = false;
    cleanupWorkers();
    emit('state', { running: false });
    emit('failed', { message });
}

function isBetterHit(
    next: NonNullable<SearchCompletedPayload['hit']>,
    current: SearchCompletedPayload['hit'],
): boolean {
    return current === null || next.index < current.index ||
        (next.index === current.index && next.mode === 'unhardened' && current.mode === 'hardened');
}

function emitProgress(checked: number, status?: string) {
    totalChecked += checked;
    const now = performance.now();
    emit('progress', {
        checked: totalChecked,
        ratePerSec: recentRate.sample(totalChecked, now),
        elapsedSecs: (now - startedAt) / 1000,
        cpuWorkers: reportedCpuWorkers,
        status,
    });
}

function normalWorkerCount(requested: number): number {
    return requested > 0 ? requested : Math.max(1, navigator.hardwareConcurrency || 1);
}

function normalChunkSize(requested: number): number {
    return Number.isFinite(requested) && requested > 0
        ? Math.max(1, Math.floor(requested))
        : 10_000;
}

function buildWorkerPlans(req: StartSearchRequest): SearchWorkerPlan[] {
    if (req.engine === 'gpu') {
        if (req.mode !== 'unhardened') {
            throw new Error('GPU search currently supports unhardened mode only');
        }
        if (typeof navigator === 'undefined' || !('gpu' in navigator)) {
            throw new Error('WebGPU is not available in this browser');
        }
        return [{ engine: 'gpu', offset: 0 }];
    }

    return Array.from({ length: normalWorkerCount(req.workerCount) }, (_, offset) => ({
        engine: 'cpu' as const,
        offset,
    }));
}

function normalizePublicKeyHex(value: string): string {
    return value.trim().toLowerCase().replace(/^0x/, '');
}

function validateKeyMaterial(req: {
    mnemonic: string;
    masterSecretKey: string;
    masterPublicKey: string;
    mode: string;
}) {
    const mnemonic = req.mnemonic.trim();
    const secretKey = normalizePublicKeyHex(req.masterSecretKey);
    const publicKey = normalizePublicKeyHex(req.masterPublicKey);
    if (secretKey && !/^[0-9a-f]{64}$/.test(secretKey)) {
        throw new Error('master secret key must be 64 hex characters');
    }
    if (publicKey && !/^[0-9a-f]{96}$/.test(publicKey)) {
        throw new Error('master public key must be 96 hex characters');
    }
    if (req.mode === 'unhardened') {
        if (!mnemonic && !secretKey && !publicKey) {
            throw new Error('mnemonic, master secret key, or master public key is required for unhardened mode');
        }
        return;
    }
    if (!mnemonic && !secretKey) {
        throw new Error('mnemonic or master secret key is required for hardened mode');
    }
}

function ensureCancelView() {
    if (typeof SharedArrayBuffer !== 'undefined') {
        cancelView = new Int32Array(new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT));
        Atomics.store(cancelView, 0, 0);
    }
}

function postStartToWorker(
    worker: Worker,
    req: StartSearchRequest,
    startIndex: number,
    endIndex: number | null,
    step: number,
    engine: 'cpu' | 'gpu',
) {
    worker.postMessage({
        type: 'start',
        payload: {
            mnemonic: req.mnemonic,
            masterSecretKey: req.masterSecretKey,
            masterPublicKey: req.masterPublicKey,
            addressPrefix: req.addressPrefix,
            wantedPrefix: req.wantedPrefix,
            wantedSuffix: req.wantedSuffix,
            startIndex,
            endIndex,
            step,
            mode: req.mode,
            searchMode: req.searchMode,
            engine,
            reportEvery: 1_000,
            cancelBuffer: cancelView?.buffer ?? null,
        },
    });
}

function startFastSearch(req: StartSearchRequest, plans: SearchWorkerPlan[], runId: number) {
    const step = plans.length;
    pendingWorkers = step;

    for (const plan of plans) {
        const worker = createWorker();
        let settled = false;
        const handleFailure = (message: string) => {
            if (!settled && running && runId === activeRunId) {
                settled = true;
                fail(message);
            }
        };

        worker.onmessage = (event: MessageEvent<any>) => {
            if (settled || !running || runId !== activeRunId) return;
            const msg = event.data;
            if (msg.type === 'progress') {
                emitProgress(Number(msg.payload.checked) || 0, msg.payload.status);
            } else if (msg.type === 'hit') {
                settled = true;
                if (cancelView) Atomics.store(cancelView, 0, 1);
                finish({ hit: msg.payload });
            } else if (msg.type === 'done') {
                settled = true;
                pendingWorkers -= 1;
                if (pendingWorkers <= 0 && running) {
                    finish(msg.payload as WorkerDonePayload);
                }
            } else if (msg.type === 'stopped') {
                settled = true;
                pendingWorkers -= 1;
                if (pendingWorkers <= 0 && running) finish({ hit: null });
            } else if (msg.type === 'error') {
                handleFailure(msg.payload.message);
            }
        };
        worker.onerror = (event) => handleFailure(event.message || 'worker failed');
        workers.push(worker);
        postStartToWorker(worker, req, req.startIndex + plan.offset, null, step, plan.engine);
    }
}

function startLowestSearch(req: StartSearchRequest, plans: SearchWorkerPlan[], runId: number) {
    const chunkSize = normalChunkSize(req.chunkSize);
    const step = plans.length;
    let chunkStart = Math.max(0, Math.floor(req.startIndex));

    const startChunk = () => {
        if (!running || runId !== activeRunId) return;
        cleanupWorkers(false);
        if (chunkStart > MAX_INDEX) {
            finish({ hit: null });
            return;
        }

        const chunkEnd = Math.min(MAX_INDEX, chunkStart + chunkSize - 1);
        pendingWorkers = step;
        bestHit = null;

        for (const plan of plans) {
            const worker = createWorker();
            let settled = false;
            const handleFailure = (message: string) => {
                if (!settled && running && runId === activeRunId) {
                    settled = true;
                    fail(message);
                }
            };

            worker.onmessage = (event: MessageEvent<any>) => {
                if (settled || !running || runId !== activeRunId) return;
                const msg = event.data;
                if (msg.type === 'progress') {
                    emitProgress(Number(msg.payload.checked) || 0, msg.payload.status);
                } else if (msg.type === 'hit') {
                    const hit = msg.payload as NonNullable<SearchCompletedPayload['hit']>;
                    if (isBetterHit(hit, bestHit)) bestHit = hit;
                } else if (msg.type === 'done') {
                    settled = true;
                    const done = msg.payload as WorkerDonePayload;
                    if (done.hit && isBetterHit(done.hit, bestHit)) bestHit = done.hit;
                    pendingWorkers -= 1;
                    if (pendingWorkers <= 0 && running) {
                        if (bestHit) finish({ hit: bestHit });
                        else if (chunkEnd >= MAX_INDEX) finish({ hit: null });
                        else {
                            chunkStart = chunkEnd + 1;
                            startChunk();
                        }
                    }
                } else if (msg.type === 'stopped') {
                    settled = true;
                    pendingWorkers -= 1;
                    if (pendingWorkers <= 0 && running) finish({ hit: bestHit });
                } else if (msg.type === 'error') {
                    handleFailure(msg.payload.message);
                }
            };
            worker.onerror = (event) => handleFailure(event.message || 'worker failed');
            workers.push(worker);
            postStartToWorker(
                worker,
                req,
                chunkStart + plan.offset,
                chunkEnd,
                step,
                plan.engine,
            );
        }
    };

    startChunk();
}

function deriveInWorker(req: DeriveAddressRequest): Promise<DeriveAddressPayload[]> {
    return new Promise((resolve, reject) => {
        const worker = createWorker();
        worker.onmessage = (event: MessageEvent<any>) => {
            const msg = event.data;
            if (msg.type === 'derived') {
                worker.terminate();
                resolve(msg.payload as DeriveAddressPayload[]);
            } else if (msg.type === 'error') {
                worker.terminate();
                reject(new Error(msg.payload.message));
            }
        };
        worker.onerror = (event) => {
            worker.terminate();
            reject(new Error(event.message || 'worker failed'));
        };
        worker.postMessage({ type: 'derive', payload: req });
    });
}

export const browserWorkerRuntime: VanityRuntime = {
    async startSearch(req) {
        if (running) throw new Error('search is already running');
        const validationError = validateWantedPatterns(req.wantedPrefix, req.wantedSuffix);
        if (validationError) throw new Error(validationError);
        validateKeyMaterial(req);
        const plans = buildWorkerPlans(req);

        running = true;
        activeRunId += 1;
        resetRunState();
        ensureCancelView();
        reportedCpuWorkers = req.engine === 'cpu' ? plans.length : undefined;
        emit('state', { running: true });
        emitProgress(0, req.engine === 'gpu' ? 'Starting GPU worker…' : 'Starting CPU workers…');

        try {
            if (req.searchMode === 'lowest' && req.engine === 'cpu') {
                startLowestSearch(req, plans, activeRunId);
            } else {
                startFastSearch(req, plans, activeRunId);
            }
        } catch (error) {
            running = false;
            cleanupWorkers();
            emit('state', { running: false });
            throw error;
        }
    },

    async stopSearch() {
        if (!running) return;
        if (cancelView) Atomics.store(cancelView, 0, 1);
        else finish({ hit: bestHit });
    },

    async deriveAddresses(req) {
        validateKeyMaterial(req);
        return deriveInWorker(req);
    },

    async getSearchState() { return { running }; },
    async onSearchProgress(cb) { return subscribe('progress', cb); },
    async onSearchCompleted(cb) { return subscribe('completed', cb); },
    async onSearchFailed(cb) { return subscribe('failed', cb); },
    async onSearchState(cb) { return subscribe('state', cb); },
};
