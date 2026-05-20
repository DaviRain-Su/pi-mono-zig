/**
 * List all pods
 */
export declare const listPods: () => void;
/**
 * Setup a new pod
 */
export declare const setupPod: (name: string, sshCmd: string, options: {
    mount?: string | undefined;
    modelsPath?: string | undefined;
    vllm?: "gpt-oss" | "nightly" | "release" | undefined;
}) => Promise<void>;
/**
 * Switch active pod
 */
export declare const switchActivePod: (name: string) => void;
/**
 * Remove a pod from config
 */
export declare const removePodCommand: (name: string) => void;
//# sourceMappingURL=pods.d.ts.map