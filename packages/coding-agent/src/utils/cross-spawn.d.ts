declare module "cross-spawn" {
	import type { ChildProcess, SpawnOptions, SpawnSyncOptions, SpawnSyncReturns } from "node:child_process";

	function crossSpawn(command: string, args?: string[], options?: SpawnOptions): ChildProcess;
	namespace crossSpawn {
		function sync(command: string, args?: string[], options?: SpawnSyncOptions): SpawnSyncReturns<string>;
	}
	export default crossSpawn;
}
