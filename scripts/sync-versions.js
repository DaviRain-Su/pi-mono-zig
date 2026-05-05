#!/usr/bin/env node

/**
 * Syncs ALL @mariozechner/* package dependency versions to match their current versions.
 * This ensures lockstep versioning across the monorepo.
 */

import { existsSync, readFileSync, writeFileSync, readdirSync } from 'fs';
import { join } from 'path';

const packagesDir = join(process.cwd(), 'packages');
const rootPackagePath = join(process.cwd(), 'package.json');
const packageDirs = readdirSync(packagesDir, { withFileTypes: true })
	.filter(dirent => dirent.isDirectory())
	.filter(dirent => existsSync(join(packagesDir, dirent.name, 'package.json')))
	.map(dirent => dirent.name);

// Read all package.json files and build version map
const packageManifests = [];
const versionMap = {};

for (const dir of packageDirs) {
	const pkgPath = join(packagesDir, dir, 'package.json');
	try {
		const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
		packageManifests.push({ path: pkgPath, data: pkg });
		versionMap[pkg.name] = pkg.version;
	} catch (e) {
		console.error(`Failed to read ${pkgPath}:`, e.message);
	}
}

try {
	const rootPkg = JSON.parse(readFileSync(rootPackagePath, 'utf8'));
	packageManifests.push({ path: rootPackagePath, data: rootPkg });
} catch (e) {
	console.error(`Failed to read ${rootPackagePath}:`, e.message);
}

console.log('Current versions:');
for (const [name, version] of Object.entries(versionMap).sort()) {
	console.log(`  ${name}: ${version}`);
}

// Verify all versions are the same (lockstep)
const versions = new Set(Object.values(versionMap));
if (versions.size > 1) {
	console.error('\n❌ ERROR: Not all packages have the same version!');
	console.error('Expected lockstep versioning. Run one of:');
	console.error('  npm run version:patch');
	console.error('  npm run version:minor');
	console.error('  npm run version:major');
	process.exit(1);
}

console.log('\n✅ All packages at same version (lockstep)');

// Update all inter-package dependencies
let totalUpdates = 0;
const dependencySections = [
	'dependencies',
	'devDependencies',
	'peerDependencies',
	'optionalDependencies',
];

for (const pkg of packageManifests) {
	let updated = false;
	
	for (const section of dependencySections) {
		if (!pkg.data[section]) continue;

		for (const [depName, currentVersion] of Object.entries(pkg.data[section])) {
			if (!versionMap[depName]) continue;

			const newVersion = `^${versionMap[depName]}`;
			if (currentVersion !== newVersion) {
				console.log(`\n${pkg.data.name}:`);
				console.log(`  ${depName}: ${currentVersion} → ${newVersion} (${section})`);
				pkg.data[section][depName] = newVersion;
				updated = true;
				totalUpdates++;
			}
		}
	}
	
	// Write if updated
	if (updated) {
		writeFileSync(pkg.path, JSON.stringify(pkg.data, null, '\t') + '\n');
	}
}

if (totalUpdates === 0) {
	console.log('\nAll inter-package dependencies already in sync.');
} else {
	console.log(`\n✅ Updated ${totalUpdates} dependency version(s)`);
}
