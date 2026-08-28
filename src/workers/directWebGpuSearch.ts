const SEARCH_BATCH_CAPACITY = 131_072;
const WORKGROUP_SIZE = 64;
const PARAM_WORDS = 136;
const NO_HIT = 0xffff_ffff;
const READBACK_BYTES = 16;
const CHILD_KEY_BYTES = 48;
const PROJECTIVE_KEY_BYTES = 160;
const BECH32_CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

export interface DirectGpuResources {
    shaderSource: string;
    tableBytes: Uint8Array;
    accountMaterial: Uint8Array;
}

export interface DirectGpuBatchResult {
    checked: number;
    elapsedMs: number;
    hitIndex?: number;
}

type StatusReporter = (status: string) => void;

function bech32Values(value: string): number[] {
    return Array.from(value, (character) => {
        const index = BECH32_CHARSET.indexOf(character);
        if (index < 0) {
            throw new Error(`Invalid Bech32 character ${JSON.stringify(character)}`);
        }
        return index;
    });
}

function searchParams(
    startIndex: number,
    count: number,
    step: number,
    addressPrefix: string,
    wantedPrefix: string,
    wantedSuffix: string,
): Uint32Array {
    const fullPrefix = `${addressPrefix}1`;
    const normalizedPrefix = wantedPrefix.toLowerCase();
    const addressDataPrefix = normalizedPrefix.startsWith(fullPrefix)
        ? normalizedPrefix.slice(fullPrefix.length)
        : normalizedPrefix;
    const prefixValues = bech32Values(addressDataPrefix);
    const suffixValues = bech32Values(wantedSuffix.toLowerCase());
    if (prefixValues.length > 64) {
        throw new Error('Address prefix is too long');
    }
    if (suffixValues.length > 58) {
        throw new Error('Address suffix is too long');
    }

    const words = new Uint32Array(PARAM_WORDS);
    words[0] = startIndex;
    words[1] = count;
    words[2] = step;
    if (addressPrefix === 'xch') {
        words[3] = 0;
    } else if (addressPrefix === 'txch') {
        words[3] = 1;
    } else {
        throw new Error('Unsupported Chia address prefix');
    }
    words[4] = prefixValues.length;
    words[5] = suffixValues.length;
    words.set(prefixValues, 8);
    words.set(suffixValues, 72);
    return words;
}

function deviceLostMessage(info: GPUDeviceLostInfo): string {
    const reason = info.reason === 'unknown' ? '' : ` (${info.reason})`;
    return `WebGPU device lost${reason}: ${info.message || 'the graphics driver reset the device'}`;
}

export class DirectWebGpuSearch {
    readonly batchCapacity = SEARCH_BATCH_CAPACITY;

    private lostMessage: string | null = null;
    private uncapturedError: string | null = null;
    private passesValidated = false;
    private freed = false;

    private constructor(
        private readonly device: GPUDevice,
        private readonly queue: GPUQueue,
        private readonly pipelines: readonly {
            label: string;
            pipeline: GPUComputePipeline;
        }[],
        private readonly paramsBuffer: GPUBuffer,
        private readonly tableBuffer: GPUBuffer,
        private readonly accountBuffer: GPUBuffer,
        private readonly hitBuffer: GPUBuffer,
        private readonly childBuffer: GPUBuffer,
        private readonly projectiveBuffer: GPUBuffer,
        private readonly readbackBuffer: GPUBuffer,
        private readonly bindGroup: GPUBindGroup,
        private readonly reportStatus: StatusReporter,
    ) {
        void device.lost.then((info) => {
            this.lostMessage = deviceLostMessage(info);
        });
        device.addEventListener('uncapturederror', (event) => {
            this.uncapturedError = event.error.message;
        });
    }

    static async create(
        resources: DirectGpuResources,
        reportStatus: StatusReporter = () => undefined,
    ): Promise<DirectWebGpuSearch> {
        if (!navigator.gpu) {
            throw new Error('WebGPU is not available in this browser');
        }
        reportStatus('Requesting high-performance GPU…');
        const adapter = await navigator.gpu.requestAdapter({
            powerPreference: 'high-performance',
        });
        if (!adapter) {
            throw new Error('No WebGPU adapter found');
        }
        reportStatus('Opening WebGPU device…');
        const device = await adapter.requestDevice();
        const queue = device.queue;
        reportStatus('Compiling GPU search code…');
        const module = device.createShaderModule({ code: resources.shaderSource });
        const compilation = await module.getCompilationInfo();
        const compilationErrors = compilation.messages.filter(
            (message) => message.type === 'error',
        );
        if (compilationErrors.length > 0) {
            const details = compilationErrors
                .map((message) =>
                    `line ${message.lineNum}:${message.linePos} ${message.message}`,
                )
                .join('\n');
            device.destroy();
            throw new Error(`WGSL compilation failed:\n${details}`);
        }

        reportStatus('Creating GPU search pipelines…');
        const layout = device.createBindGroupLayout({
            entries: [
                {
                    binding: 0,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: 'read-only-storage' },
                },
                {
                    binding: 1,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: 'read-only-storage' },
                },
                {
                    binding: 2,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: 'read-only-storage' },
                },
                {
                    binding: 3,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: 'storage' },
                },
                {
                    binding: 4,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: 'storage' },
                },
                {
                    binding: 5,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: 'storage' },
                },
            ],
        });
        const pipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [layout] });
        const pipelines = [
            ['child multiplication', 'child_multiply_kernel'],
            ['child normalization', 'child_finish_kernel'],
            ['synthetic multiplication', 'synthetic_multiply_kernel'],
            ['address filtering', 'search_finish_kernel'],
        ].map(([label, entryPoint]) => ({
            label,
            pipeline: device.createComputePipeline({
                layout: pipelineLayout,
                compute: { module, entryPoint },
            }),
        }));
        reportStatus('Allocating reusable GPU memory…');
        const paramsBuffer = device.createBuffer({
            size: PARAM_WORDS * Uint32Array.BYTES_PER_ELEMENT,
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
        });
        const tableBuffer = device.createBuffer({
            size: resources.tableBytes.byteLength,
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
        });
        const accountBuffer = device.createBuffer({
            size: resources.accountMaterial.byteLength,
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
        });
        const hitBuffer = device.createBuffer({
            size: READBACK_BYTES,
            usage:
                GPUBufferUsage.STORAGE |
                GPUBufferUsage.COPY_DST |
                GPUBufferUsage.COPY_SRC,
        });
        const childBuffer = device.createBuffer({
            size: SEARCH_BATCH_CAPACITY * CHILD_KEY_BYTES,
            usage: GPUBufferUsage.STORAGE,
        });
        const projectiveBuffer = device.createBuffer({
            size: SEARCH_BATCH_CAPACITY * PROJECTIVE_KEY_BYTES,
            usage: GPUBufferUsage.STORAGE,
        });
        const readbackBuffer = device.createBuffer({
            size: READBACK_BYTES,
            usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
        });
        queue.writeBuffer(tableBuffer, 0, resources.tableBytes);
        queue.writeBuffer(accountBuffer, 0, resources.accountMaterial);
        const bindGroup = device.createBindGroup({
            layout,
            entries: [
                { binding: 0, resource: { buffer: paramsBuffer } },
                { binding: 1, resource: { buffer: accountBuffer } },
                { binding: 2, resource: { buffer: tableBuffer } },
                { binding: 3, resource: { buffer: hitBuffer } },
                { binding: 4, resource: { buffer: childBuffer } },
                { binding: 5, resource: { buffer: projectiveBuffer } },
            ],
        });

        return new DirectWebGpuSearch(
            device,
            queue,
            pipelines,
            paramsBuffer,
            tableBuffer,
            accountBuffer,
            hitBuffer,
            childBuffer,
            projectiveBuffer,
            readbackBuffer,
            bindGroup,
            reportStatus,
        );
    }

    async searchBatch(
        startIndex: number,
        count: number,
        step: number,
        addressPrefix: string,
        wantedPrefix: string,
        wantedSuffix: string,
    ): Promise<DirectGpuBatchResult> {
        if (count < 1 || count > this.batchCapacity) {
            throw new Error('Count must be within the GPU batch capacity');
        }
        if (step < 1) {
            throw new Error('Step must be greater than zero');
        }
        if (this.lostMessage) {
            throw new Error(this.lostMessage);
        }

        const started = performance.now();
        this.queue.writeBuffer(
            this.paramsBuffer,
            0,
            searchParams(
                startIndex,
                count,
                step,
                addressPrefix,
                wantedPrefix,
                wantedSuffix,
            ),
        );
        this.queue.writeBuffer(
            this.hitBuffer,
            0,
            new Uint32Array([NO_HIT, 0, 0, 0]),
        );

        const workgroups = Math.ceil(count / WORKGROUP_SIZE);
        if (!this.passesValidated) {
            for (const { label, pipeline } of this.pipelines) {
                this.reportStatus(`Warming up GPU: ${label}…`);
                const encoder = this.device.createCommandEncoder();
                const pass = encoder.beginComputePass();
                pass.setPipeline(pipeline);
                pass.setBindGroup(0, this.bindGroup);
                pass.dispatchWorkgroups(workgroups);
                pass.end();
                this.queue.submit([encoder.finish()]);
                try {
                    await this.queue.onSubmittedWorkDone();
                } catch (error) {
                    await Promise.resolve();
                    const detail = this.lostMessage ?? this.uncapturedError ??
                        (error instanceof Error ? error.message : String(error));
                    throw new Error(`GPU ${label} pass failed: ${detail}`);
                }
            }
            this.passesValidated = true;
            this.reportStatus('GPU ready; searching…');
        } else {
            const encoder = this.device.createCommandEncoder();
            for (const { pipeline } of this.pipelines) {
                const pass = encoder.beginComputePass();
                pass.setPipeline(pipeline);
                pass.setBindGroup(0, this.bindGroup);
                pass.dispatchWorkgroups(workgroups);
                pass.end();
            }
            this.queue.submit([encoder.finish()]);
        }

        const readbackEncoder = this.device.createCommandEncoder();
        readbackEncoder.copyBufferToBuffer(
            this.hitBuffer,
            0,
            this.readbackBuffer,
            0,
            READBACK_BYTES,
        );
        this.queue.submit([readbackEncoder.finish()]);

        try {
            await this.readbackBuffer.mapAsync(GPUMapMode.READ);
        } catch (error) {
            await Promise.resolve();
            const detail = this.lostMessage ?? this.uncapturedError;
            throw new Error(
                detail ??
                (error instanceof Error ? error.message : String(error)),
            );
        }
        const hit = new Uint32Array(
            this.readbackBuffer.getMappedRange().slice(0, Uint32Array.BYTES_PER_ELEMENT),
        )[0];
        this.readbackBuffer.unmap();

        return {
            checked: count,
            elapsedMs: performance.now() - started,
            ...(hit === NO_HIT ? {} : { hitIndex: hit }),
        };
    }

    free() {
        if (this.freed) return;
        this.freed = true;
        if (this.readbackBuffer.mapState === 'mapped') {
            this.readbackBuffer.unmap();
        }
        this.paramsBuffer.destroy();
        this.tableBuffer.destroy();
        this.accountBuffer.destroy();
        this.hitBuffer.destroy();
        this.childBuffer.destroy();
        this.projectiveBuffer.destroy();
        this.readbackBuffer.destroy();
        this.device.destroy();
    }
}
