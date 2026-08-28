type RateSample = { at: number; total: number };

export class RecentRate {
    private samples: RateSample[] = [];

    constructor(private readonly windowMs = 10_000) {}

    reset(at = performance.now()) {
        this.samples = [{ at, total: 0 }];
    }

    sample(total: number, at = performance.now()): number {
        const latest = this.samples[this.samples.length - 1];
        if (!latest || latest.total !== total) {
            this.samples.push({ at, total });
        }

        const cutoff = at - this.windowMs;
        while (this.samples.length > 2 && this.samples[1].at <= cutoff) {
            this.samples.shift();
        }

        const first = this.samples[0];
        const elapsedSecs = (at - first.at) / 1000;
        return elapsedSecs > 0 ? (total - first.total) / elapsedSecs : 0;
    }
}
