/**
 * Start a model
 */
export declare const startModel: (modelId: string, name: string, options: {
    pod?: string | undefined;
    vllmArgs?: string[] | undefined;
    memory?: string | undefined;
    context?: string | undefined;
    gpus?: number | undefined;
}) => Promise<void>;
/**
 * Stop a model
 */
export declare const stopModel: (name: string, options: {
    pod?: string | undefined;
}) => Promise<void>;
/**
 * Stop all models on a pod
 */
export declare const stopAllModels: (options: {
    pod?: string | undefined;
}) => Promise<void>;
/**
 * List all models
 */
export declare const listModels: (options: {
    pod?: string | undefined;
}) => Promise<void>;
/**
 * View model logs
 */
export declare const viewLogs: (name: string, options: {
    pod?: string | undefined;
}) => Promise<void>;
/**
 * Show known models and their hardware requirements
 */
export declare const showKnownModels: () => Promise<void>;
//# sourceMappingURL=models.d.ts.map