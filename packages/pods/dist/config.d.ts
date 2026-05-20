import type { Config, Pod } from "./types.js";
export declare const loadConfig: () => Config;
export declare const saveConfig: (config: Config) => void;
export declare const getActivePod: () => {
    name: string;
    pod: Pod;
} | null;
export declare const addPod: (name: string, pod: Pod) => void;
export declare const removePod: (name: string) => void;
export declare const setActivePod: (name: string) => void;
//# sourceMappingURL=config.d.ts.map