export interface GPU {
    id: number;
    name: string;
    memory: string;
}
export interface Model {
    model: string;
    port: number;
    gpu: number[];
    pid: number;
}
export interface Pod {
    ssh: string;
    gpus: GPU[];
    models: Record<string, Model>;
    modelsPath?: string;
    vllmVersion?: "release" | "nightly" | "gpt-oss";
}
export interface Config {
    pods: Record<string, Pod>;
    active?: string;
}
//# sourceMappingURL=types.d.ts.map