import { randomBytes } from "node:crypto";
import { createWriteStream, type WriteStream } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExecutionEnv, ExecutionEnvExecOptions } from "../types.js";
import { DEFAULT_MAX_BYTES, truncateTail } from "./truncate.js";

export interface ShellCaptureOptions extends Omit<ExecutionEnvExecOptions, "onStdout" | "onStderr"> {
	onChunk?: (chunk: string) => void;
}

export interface ShellCaptureResult {
	output: string;
	exitCode: number | undefined;
	cancelled: boolean;
	truncated: boolean;
	fullOutputPath?: string;
}

export function sanitizeBinaryOutput(str: string): string {
	return Array.from(str)
		.filter((char) => {
			const code = char.codePointAt(0);
			if (code === undefined) return false;
			if (code === 0x09 || code === 0x0a || code === 0x0d) return true;
			if (code <= 0x1f) return false;
			if (code >= 0xfff9 && code <= 0xfffb) return false;
			return true;
		})
		.join("");
}

export async function executeShellWithCapture(
	env: ExecutionEnv,
	command: string,
	options?: ShellCaptureOptions,
): Promise<ShellCaptureResult> {
	const outputChunks: string[] = [];
	let outputBytes = 0;
	const maxOutputBytes = DEFAULT_MAX_BYTES * 2;

	let tempFilePath: string | undefined;
	let tempFileStream: WriteStream | undefined;
	let totalBytes = 0;

	const ensureTempFile = () => {
		if (tempFilePath) return;
		const id = randomBytes(8).toString("hex");
		tempFilePath = join(tmpdir(), `bash-${id}.log`);
		tempFileStream = createWriteStream(tempFilePath);
		for (const chunk of outputChunks) {
			tempFileStream.write(chunk);
		}
	};

	const onChunk = (chunk: string) => {
		totalBytes += Buffer.byteLength(chunk, "utf-8");
		const text = sanitizeBinaryOutput(chunk).replace(/\r/g, "");
		if (totalBytes > DEFAULT_MAX_BYTES) {
			ensureTempFile();
		}
		if (tempFileStream) {
			tempFileStream.write(text);
		}
		outputChunks.push(text);
		outputBytes += text.length;
		while (outputBytes > maxOutputBytes && outputChunks.length > 1) {
			const removed = outputChunks.shift()!;
			outputBytes -= removed.length;
		}
		options?.onChunk?.(text);
	};

	try {
		const result = await env.exec(command, {
			...(options ?? {}),
			onStdout: onChunk,
			onStderr: onChunk,
		});
		const fullOutput = outputChunks.join("");
		const truncationResult = truncateTail(fullOutput);
		if (truncationResult.truncated) {
			ensureTempFile();
		}
		tempFileStream?.end();
		const cancelled = options?.signal?.aborted ?? false;
		return {
			output: truncationResult.truncated ? truncationResult.content : fullOutput,
			exitCode: cancelled ? undefined : result.exitCode,
			cancelled,
			truncated: truncationResult.truncated,
			fullOutputPath: tempFilePath,
		};
	} catch (err) {
		if (options?.signal?.aborted) {
			const fullOutput = outputChunks.join("");
			const truncationResult = truncateTail(fullOutput);
			if (truncationResult.truncated) {
				ensureTempFile();
			}
			tempFileStream?.end();
			return {
				output: truncationResult.truncated ? truncationResult.content : fullOutput,
				exitCode: undefined,
				cancelled: true,
				truncated: truncationResult.truncated,
				fullOutputPath: tempFilePath,
			};
		}
		tempFileStream?.end();
		throw err;
	}
}
