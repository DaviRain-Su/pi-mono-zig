import { describe, expect, it } from "vitest";
import { parseStreamingJson } from "../src/utils/json-parse.js";

describe("parseStreamingJson", () => {
	it("parses complete JSON", () => {
		const result = parseStreamingJson('{"foo": 123}');
		expect(result).toEqual({ foo: 123 });
	});

	it("returns empty object for empty string", () => {
		const result = parseStreamingJson("");
		expect(result).toEqual({});
	});

	it("returns empty object for undefined", () => {
		const result = parseStreamingJson(undefined);
		expect(result).toEqual({});
	});

	it("parses partial JSON with partial-json fallback", () => {
		const result = parseStreamingJson('{"foo": 123, "bar');
		expect(result).toEqual({ foo: 123 });
	});
});
