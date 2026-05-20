import { attachTool } from "./attach.js";
import { createBashTool } from "./bash.js";
import { createEditTool } from "./edit.js";
import { createReadTool } from "./read.js";
import { createWriteTool } from "./write.js";
export { setUploadFunction } from "./attach.js";
export function createMomTools(executor) {
    return [
        createReadTool(executor),
        createBashTool(executor),
        createEditTool(executor),
        createWriteTool(executor),
        attachTool,
    ];
}
//# sourceMappingURL=index.js.map