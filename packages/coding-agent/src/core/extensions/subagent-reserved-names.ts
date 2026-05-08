import type { ExtensionFactory } from "./types.js";

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

const SUB_AGENT_EXTENSION_FACTORY_BRAND: unique symbol = Symbol.for("pi.subAgentExtensionFactory");

type SubAgentExtensionFactory = ExtensionFactory & {
	[SUB_AGENT_EXTENSION_FACTORY_BRAND]?: true;
};

export function markSubAgentExtensionFactory(factory: ExtensionFactory): ExtensionFactory {
	Object.defineProperty(factory, SUB_AGENT_EXTENSION_FACTORY_BRAND, {
		value: true,
		configurable: false,
		enumerable: false,
		writable: false,
	});
	return factory;
}

export function isSubAgentExtensionFactory(factory: ExtensionFactory): boolean {
	return (factory as SubAgentExtensionFactory)[SUB_AGENT_EXTENSION_FACTORY_BRAND] === true;
}

export function isSubAgentReservedName(name: string): boolean {
	return SUB_AGENT_RESERVED_NAMES.has(name) || name.startsWith(SUB_AGENT_RESERVED_PREFIX);
}

export function assertSubAgentReservedNameAllowed(
	name: string,
	ownerAllowed: boolean | undefined,
	operation: string,
): void {
	if (!isSubAgentReservedName(name) || ownerAllowed === true) {
		return;
	}
	throw new Error(`Cannot ${operation} reserved sub-agent substrate name "${name}" from an unrelated extension.`);
}
