import { appendFileSync } from "node:fs";
import readline from "node:readline/promises";

const marker = process.argv[2] ?? process.env.PI_M6_EXTENSION_HOST_MARKER ?? "pi-m6-extension-host";
const capturePath = process.env.PI_M6_EXTENSION_HOST_CAPTURE;

function capture(record) {
	if (!capturePath) return;
	appendFileSync(capturePath, `${JSON.stringify(record)}\n`);
}

function emit(record) {
	process.stdout.write(`${JSON.stringify(record)}\n`);
	capture({ event: "host_stdout", type: record.type, id: record.id, method: record.method });
}

const rl = readline.createInterface({
	input: process.stdin,
	crlfDelay: Infinity,
});
const input = rl[Symbol.asyncIterator]();

async function nextLine() {
	const result = await input.next();
	return result.done ? undefined : result.value;
}

function parseLine(line) {
	try {
		return JSON.parse(line);
	} catch {
		capture({ event: "malformed_input" });
		return undefined;
	}
}

const initializeLine = await nextLine();
if (initializeLine === undefined) {
	process.exit(2);
}
const initialize = parseLine(initializeLine);
capture({
	event: "initialize",
	marker: initialize?.marker ?? marker,
	fixture: initialize?.fixture ?? "unknown",
});

emit({ type: "ready" });
capture({ event: "ready" });

const pending = new Set();
const responses = new Map();
function request(record, responseRequired = false) {
	emit(responseRequired ? { ...record, responseRequired: true } : record);
	if (responseRequired) pending.add(record.id);
}

request(
	{
		type: "extension_ui_request",
		id: "ui_select",
		method: "select",
		payload: { title: "Choose fixture", options: ["option-a", "option-b"], timeout: 1000 },
	},
	true,
);
request(
	{
		type: "extension_ui_request",
		id: "ui_confirm",
		method: "confirm",
		payload: { title: "Confirm fixture", message: "Proceed?", timeout: 1000 },
	},
	true,
);
request(
	{
		type: "extension_ui_request",
		id: "ui_input",
		method: "input",
		payload: { title: "Fixture input", placeholder: "value", timeout: 1000 },
	},
	true,
);
request({
	type: "extension_ui_request",
	id: "ui_notify",
	method: "notify",
	payload: { message: "Fixture notice", notifyType: "info" },
});
request({
	type: "extension_ui_request",
	id: "ui_status",
	method: "setStatus",
	payload: { statusKey: "fixture", statusText: "ready" },
});
request({
	type: "extension_ui_request",
	id: "ui_widget",
	method: "setWidget",
	payload: { widgetKey: "fixture", widgetLines: ["line one", "line two"], widgetPlacement: "aboveEditor" },
});
request({
	type: "extension_ui_request",
	id: "ui_title",
	method: "setTitle",
	payload: { title: "Fixture Title" },
});
request({
	type: "extension_ui_request",
	id: "ui_editor_text",
	method: "set_editor_text",
	payload: { text: "fixture editor text" },
});
request(
	{
		type: "extension_ui_request",
		id: "ui_editor",
		method: "editor",
		payload: { title: "Edit fixture", prefill: "prefill" },
	},
	true,
);

while (pending.size > 0) {
	const line = await nextLine();
	if (line === undefined) process.exit(3);
	const message = parseLine(line);
	if (message?.type !== "extension_ui_response" || !pending.has(message.id)) continue;
	responses.set(message.id, message.payload);
	pending.delete(message.id);
	capture({ event: "response", id: message.id, payload: message.payload });
}

const selectValue = responses.get("ui_select")?.value ?? "option-b";
const confirmed = responses.get("ui_confirm")?.confirmed ?? true;
const inputValue = responses.get("ui_input")?.value ?? "cancelled";
const editorValue = responses.get("ui_editor")?.value ?? "edited text";
capture({
	event: "completion",
	result: {
		select: selectValue,
		confirmed,
		input: inputValue,
		editor: editorValue,
	},
});
request({
	type: "extension_ui_request",
	id: "ui_m6_complete",
	method: "setStatus",
	payload: {
		statusKey: "fixture",
		statusText: `complete:${selectValue}:${confirmed}:${inputValue}:${editorValue}`,
	},
});

while (true) {
	const line = await nextLine();
	if (line === undefined) break;
	const message = parseLine(line);
	if (message?.type === "shutdown") {
		capture({ event: "shutdown" });
		emit({ type: "shutdown_complete" });
		break;
	}
}

rl.close();
