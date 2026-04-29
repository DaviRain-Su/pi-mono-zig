import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseStreamingJson } from "../../packages/ai/src/utils/json-parse.js";

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = dirname(scriptPath);
const fixtureDir = join(scriptDir, "golden", "json-parse");
const fixturePath = join(fixtureDir, "cases.jsonl");
const checkMode = process.argv.includes("--check");

interface JsonParseFixtureCase {
	name: string;
	input: string | null;
	category: string;
}

interface JsonParseFixtureRecord extends JsonParseFixtureCase {
	expected: string;
	source: "packages/ai/src/utils/json-parse.ts";
}

const danglingBackslash = '{"path":"C:' + "\\";

const cases: JsonParseFixtureCase[] = [
	{ name: "empty absent input", input: null, category: "empty" },
	{ name: "empty string input", input: "", category: "empty" },
	{ name: "empty whitespace input", input: " \t\r\n ", category: "empty" },
	{
		name: "complete object preserves semantics",
		input: '{"foo":123,"bar":"baz","nested":{"ok":true},"arr":[1,"two",null]}',
		category: "complete",
	},
	{ name: "complete array preserves semantics", input: '[1,2,{"x":true}]', category: "complete" },
	{ name: "primitive number follows baseline", input: "123", category: "primitive" },
	{ name: "primitive string follows baseline", input: '"hello"', category: "primitive" },
	{ name: "primitive boolean follows baseline", input: "true", category: "primitive" },
	{ name: "partial object drops incomplete trailing key", input: '{"foo":123,"bar', category: "partial-object" },
	{ name: "partial object keeps partial string value", input: '{"foo":"hel', category: "partial-object" },
	{ name: "partial array drops dangling separator", input: "[1,2,", category: "partial-array" },
	{ name: "partial array drops incomplete object value", input: '[{"a":1},{"b":', category: "partial-array" },
	{ name: "nested partial object array", input: '{"a":{"b":[1,2,', category: "nested-partial" },
	{
		name: "nested partial object in array",
		input: '{"items":[{"id":1},{"id":2,"name":"tw',
		category: "nested-partial",
	},
	{ name: "invalid escape repaired", input: String.raw`{"path":"A\H"}`, category: "invalid-escape" },
	{
		name: "incomplete unicode escape repaired",
		input: String.raw`{"text":"\u12"}`,
		category: "invalid-escape",
	},
	{ name: "dangling backslash repaired", input: danglingBackslash, category: "invalid-escape" },
	{ name: "raw control character escaped", input: '{"text":"a\tb"}', category: "raw-control" },
	{ name: "trailing garbage uses stable prefix", input: '{"a":1} trailing', category: "non-recoverable" },
	{ name: "non json prose falls back", input: "not json", category: "non-recoverable" },
	{ name: "corrupt object falls back", input: "{bad", category: "non-recoverable" },
];

function expectedJson(input: string | null): string {
	return JSON.stringify(parseStreamingJson<unknown>(input === null ? undefined : input));
}

function buildRecords(): JsonParseFixtureRecord[] {
	return cases.map((testCase) => ({
		...testCase,
		expected: expectedJson(testCase.input),
		source: "packages/ai/src/utils/json-parse.ts",
	}));
}

function serializeRecords(records: JsonParseFixtureRecord[]): string {
	return `${records.map((record) => JSON.stringify(record)).join("\n")}\n`;
}

const nextContents = serializeRecords(buildRecords());

if (checkMode) {
	if (!existsSync(fixturePath)) {
		throw new Error(`Missing JSON parse fixture file: ${fixturePath}`);
	}
	const currentContents = readFileSync(fixturePath, "utf8");
	if (currentContents !== nextContents) {
		throw new Error("JSON parse fixtures are stale. Run `npx tsx test/generate-json-parse-fixtures.ts`.");
	}
	console.log("JSON parse fixtures are up to date");
} else {
	mkdirSync(fixtureDir, { recursive: true });
	writeFileSync(fixturePath, nextContents);
	console.log(`Wrote ${cases.length} JSON parse fixtures to ${fixturePath}`);
}
