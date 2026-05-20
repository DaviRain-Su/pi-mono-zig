import type { GPU } from "./types.js";
/**
 * Get the best configuration for a model based on available GPUs
 */
export declare const getModelConfig: (modelId: string, gpus: GPU[], requestedGpuCount: number) => {
    args: string[];
    env?: Record<string, string> | undefined;
    notes?: string | undefined;
} | null;
/**
 * Check if a model is known
 */
export declare const isKnownModel: (modelId: string) => boolean;
/**
 * Get all known models
 */
export declare const getKnownModels: () => string[];
/**
 * Get model display name
 */
export declare const getModelName: (modelId: string) => string;
//# sourceMappingURL=model-configs.d.ts.map