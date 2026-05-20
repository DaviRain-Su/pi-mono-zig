import type { ExtensionFactory } from "./types.js";
export declare function markSubAgentExtensionFactory(factory: ExtensionFactory): ExtensionFactory;
export declare function isSubAgentExtensionFactory(factory: ExtensionFactory): boolean;
export declare function isSubAgentReservedName(name: string): boolean;
export declare function assertSubAgentReservedNameAllowed(name: string, ownerAllowed: boolean | undefined, operation: string): void;
//# sourceMappingURL=subagent-reserved-names.d.ts.map