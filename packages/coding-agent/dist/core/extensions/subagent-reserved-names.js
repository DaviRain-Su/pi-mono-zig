const SUB_AGENT_RESERVED_PREFIX = "sub_agent.";
const SUB_AGENT_RESERVED_NAMES = new Set([
    "sub_agent.delegate",
    "sub_agent.readiness",
    "sub_agent.delegation.result",
    "sub_agent.status",
    "sub_agent_readiness",
    "sub-agent",
    "/sub-agent",
]);
const SUB_AGENT_EXTENSION_FACTORY_BRAND = Symbol.for("pi.subAgentExtensionFactory");
export function markSubAgentExtensionFactory(factory) {
    Object.defineProperty(factory, SUB_AGENT_EXTENSION_FACTORY_BRAND, {
        value: true,
        configurable: false,
        enumerable: false,
        writable: false,
    });
    return factory;
}
export function isSubAgentExtensionFactory(factory) {
    return factory[SUB_AGENT_EXTENSION_FACTORY_BRAND] === true;
}
export function isSubAgentReservedName(name) {
    return SUB_AGENT_RESERVED_NAMES.has(name) || name.startsWith(SUB_AGENT_RESERVED_PREFIX);
}
export function assertSubAgentReservedNameAllowed(name, ownerAllowed, operation) {
    if (!isSubAgentReservedName(name) || ownerAllowed === true) {
        return;
    }
    throw new Error(`Cannot ${operation} reserved sub-agent substrate name "${name}" from an unrelated extension.`);
}
//# sourceMappingURL=subagent-reserved-names.js.map