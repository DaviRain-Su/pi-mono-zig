/// Thin backward-compatibility wrapper.
///
/// Capability types and manifest validation have moved to
/// `extensions/capability.zig` and `extensions/manifest.zig`.
/// This module re-exports the public API so existing imports
/// continue to compile. New code should import the upstream
/// modules directly.
const capability = @import("../capability.zig");
const manifest = @import("../manifest.zig");

// Capability system
pub const LifecyclePhase = capability.LifecyclePhase;
pub const Capability = capability.Capability;
pub const CANONICAL_CAPABILITIES = capability.CANONICAL_CAPABILITIES;
pub const CapabilityEnforcementBranch = capability.CapabilityEnforcementBranch;
pub const CapabilityDenialDiagnostic = capability.CapabilityDenialDiagnostic;
pub const ResourceLimits = capability.ResourceLimits;

pub const denyFirstUnapprovedCapability = capability.denyFirstUnapprovedCapability;
pub const denyRuntimeCapability = capability.denyRuntimeCapability;
pub const denyRuntimeImport = capability.denyRuntimeImport;
pub const runtimeImportCapability = capability.runtimeImportCapability;
pub const parseCapability = capability.parseCapability;

// Manifest system
pub const MANIFEST_FILE_NAME = manifest.MANIFEST_FILE_NAME;
pub const SCHEMA_VERSION = manifest.SCHEMA_VERSION;
pub const ARTIFACT_DIGEST_MISMATCH_CATEGORY = manifest.ARTIFACT_DIGEST_MISMATCH_CATEGORY;
pub const ARTIFACT_INVALID_CATEGORY = manifest.ARTIFACT_INVALID_CATEGORY;
pub const ArtifactKind = manifest.ArtifactKind;
pub const Diagnostic = manifest.Diagnostic;
pub const DiagnosticPrincipal = manifest.DiagnosticPrincipal;
pub const DiagnosticSource = manifest.DiagnosticSource;
pub const Manifest = manifest.Manifest;
pub const ValidationResult = manifest.ValidationResult;
pub const ValidationOptions = manifest.ValidationOptions;

pub const validateManifestText = manifest.validateManifestText;
pub const validateManifestTextWithOptions = manifest.validateManifestTextWithOptions;
pub const validateManifestFile = manifest.validateManifestFile;
pub const validateManifestFileWithOptions = manifest.validateManifestFileWithOptions;
pub const packageTrustPrincipalInputs = manifest.packageTrustPrincipalInputs;
pub const verifyArtifactSha256 = manifest.verifyArtifactSha256;
pub const computeArtifactSha256 = manifest.computeArtifactSha256;
pub const computePackageRootSha256 = manifest.computePackageRootSha256;
