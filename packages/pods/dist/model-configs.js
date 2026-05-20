import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
// Load models configuration - resolve relative to this file
const modelsJsonPath = join(__dirname, "models.json");
const modelsData = JSON.parse(readFileSync(modelsJsonPath, "utf-8"));
/**
 * Get the best configuration for a model based on available GPUs
 */
export const getModelConfig = (modelId, gpus, requestedGpuCount) => {
    const modelInfo = modelsData.models[modelId];
    if (!modelInfo) {
        // Unknown model, no default config
        return null;
    }
    // Extract GPU type from the first GPU name (e.g., "NVIDIA H200" -> "H200")
    const gpuType = gpus[0]?.name?.replace("NVIDIA", "")?.trim()?.split(" ")[0] || "";
    // Find best matching config
    let bestConfig = null;
    for (const config of modelInfo.configs) {
        // Check GPU count
        if (config.gpuCount !== requestedGpuCount) {
            continue;
        }
        // Check GPU type if specified
        if (config.gpuTypes && config.gpuTypes.length > 0) {
            const typeMatches = config.gpuTypes.some((type) => gpuType.includes(type) || type.includes(gpuType));
            if (!typeMatches) {
                continue;
            }
        }
        // This config matches
        bestConfig = config;
        break;
    }
    // If no exact match, try to find a config with just the right GPU count
    if (!bestConfig) {
        for (const config of modelInfo.configs) {
            if (config.gpuCount === requestedGpuCount) {
                bestConfig = config;
                break;
            }
        }
    }
    if (!bestConfig) {
        // No suitable config found
        return null;
    }
    return {
        args: [...bestConfig.args],
        env: bestConfig.env ? { ...bestConfig.env } : undefined,
        notes: bestConfig.notes || modelInfo.notes,
    };
};
/**
 * Check if a model is known
 */
export const isKnownModel = (modelId) => {
    return modelId in modelsData.models;
};
/**
 * Get all known models
 */
export const getKnownModels = () => {
    return Object.keys(modelsData.models);
};
/**
 * Get model display name
 */
export const getModelName = (modelId) => {
    return modelsData.models[modelId]?.name || modelId;
};
//# sourceMappingURL=model-configs.js.map