import { Type } from "@sinclair/typebox";
import { basename, resolve as resolvePath } from "path";
// This will be set by the agent before running
let uploadFn = null;
export function setUploadFunction(fn) {
    uploadFn = fn;
}
const attachSchema = Type.Object({
    label: Type.String({ description: "Brief description of what you're sharing (shown to user)" }),
    path: Type.String({ description: "Path to the file to attach" }),
    title: Type.Optional(Type.String({ description: "Title for the file (defaults to filename)" })),
});
export const attachTool = {
    name: "attach",
    label: "attach",
    description: "Attach a file to your response. Use this to share files, images, or documents with the user. Only files from /workspace/ can be attached.",
    parameters: attachSchema,
    execute: async (_toolCallId, { path, title }, signal) => {
        if (!uploadFn) {
            throw new Error("Upload function not configured");
        }
        if (signal?.aborted) {
            throw new Error("Operation aborted");
        }
        const absolutePath = resolvePath(path);
        const fileName = title || basename(absolutePath);
        await uploadFn(absolutePath, fileName);
        return {
            content: [{ type: "text", text: `Attached file: ${fileName}` }],
            details: undefined,
        };
    },
};
//# sourceMappingURL=attach.js.map