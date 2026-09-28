from __future__ import annotations

import json
import re
from pathlib import Path

from .models import (
    Inventory,
    MappingStatus,
    MigrationReport,
    MigrationSummary,
    PackageMapping,
    PackageResult,
    RiskLevel,
    RuntimeAvailability,
    RuntimeResult,
)

MAPPINGS_DIR = Path(__file__).resolve().parent.parent / "mappings"

MAPPING_FILE_MAP = {
    ("al2", "rhel8"): "al2_to_rhel8.json",
    ("al2", "rhel9"): "al2_to_rhel9.json",
    ("al2", "rhel10"): "al2_to_rhel9.json",
    ("al2023", "rhel9"): "al2023_to_rhel9.json",
    ("al2023", "rhel10"): "al2023_to_rhel10.json",
}

STATUS_TO_RISK = {
    MappingStatus.DIRECT: RiskLevel.GREEN,
    MappingStatus.RENAMED: RiskLevel.YELLOW,
    MappingStatus.REPLACED: RiskLevel.YELLOW,
    MappingStatus.REMOVED: RiskLevel.RED,
    MappingStatus.MANUAL: RiskLevel.RED,
    MappingStatus.UNKNOWN: RiskLevel.GRAY,
}

RUNTIME_KEY_ALIASES = {
    "java": ["java"],
    "python": ["python"],
    "nodejs": ["nodejs", "node"],
    "ruby": ["ruby"],
    "go": ["go", "golang"],
    "php": ["php"],
    "dotnet": ["dotnet", ".net"],
    "perl": ["perl"],
}


def _load_package_mappings(source_os: str, target_os: str) -> dict[str, PackageMapping]:
    key = (source_os, target_os)
    filename = MAPPING_FILE_MAP.get(key)
    if not filename:
        return {}
    path = MAPPINGS_DIR / "packages" / filename
    if not path.exists():
        return {}
    with open(path) as f:
        raw = json.load(f)
    return {name: PackageMapping(**data) for name, data in raw.items()}


def _load_runtime_mappings(target_os: str) -> dict[str, list[RuntimeAvailability]]:
    path = MAPPINGS_DIR / "runtimes.json"
    if not path.exists():
        return {}
    with open(path) as f:
        raw = json.load(f)
    target_data = raw.get(target_os, {})
    result: dict[str, list[RuntimeAvailability]] = {}
    for runtime, entries in target_data.items():
        result[runtime] = [RuntimeAvailability(**e) for e in entries]
    return result


def _normalize_version(version_str: str) -> str:
    version_str = version_str.strip().lstrip("v")
    match = re.match(r"(\d+(?:\.\d+)*)", version_str)
    return match.group(1) if match else version_str


def _major_minor(version_str: str) -> str:
    parts = _normalize_version(version_str).split(".")
    return ".".join(parts[:2]) if len(parts) >= 2 else parts[0]


def _version_available(installed: str, available_versions: list[str]) -> tuple[bool, str]:
    installed_mm = _major_minor(installed)
    installed_major = installed_mm.split(".")[0]

    for av in available_versions:
        if _major_minor(av) == installed_mm:
            return True, av
    for av in available_versions:
        if av.split(".")[0] == installed_major:
            return True, av
    return False, ""


def _detect_source_os(inventory: Inventory) -> str:
    al_version = inventory.os.al_version
    if al_version in ("al2", "al2023"):
        return al_version
    version = inventory.os.version
    if version == "2":
        return "al2"
    if version == "2023":
        return "al2023"
    os_id = inventory.os.id
    if os_id == "amzn":
        return "al2"
    return "unknown"


def _suggest_target(source_os: str) -> str:
    if source_os == "al2":
        return "rhel8"
    return "rhel9"


def analyze(inventory: Inventory, target_os: str) -> MigrationReport:
    source_os = _detect_source_os(inventory)
    if not target_os:
        target_os = _suggest_target(source_os)
    target_os = target_os.lower().replace(" ", "").replace("-", "")
    if not target_os.startswith("rhel"):
        target_os = f"rhel{target_os}"

    pkg_mappings = _load_package_mappings(source_os, target_os)
    runtime_mappings = _load_runtime_mappings(target_os)

    package_results = _analyze_packages(inventory, pkg_mappings)
    runtime_results = _analyze_runtimes(inventory, runtime_mappings)
    summary = _build_summary(package_results, runtime_results)

    source_label = "Amazon Linux 2" if source_os == "al2" else "Amazon Linux 2023"
    target_label = target_os.upper().replace("RHEL", "RHEL ")

    return MigrationReport(
        source_os=source_label,
        target_os=target_label,
        inventory_generated_at=inventory.generated_at,
        hostname=inventory.os.hostname,
        summary=summary,
        packages=package_results,
        runtimes=runtime_results,
        services=inventory.services_running,
        network_listeners=inventory.network_listeners,
    )


def _analyze_packages(
    inventory: Inventory, mappings: dict[str, PackageMapping]
) -> list[PackageResult]:
    results: list[PackageResult] = []
    for pkg in inventory.packages:
        mapping = mappings.get(pkg.name)
        if mapping:
            status = mapping.status
            risk = STATUS_TO_RISK[status]
            results.append(
                PackageResult(
                    name=pkg.name,
                    installed_version=f"{pkg.version}-{pkg.release}" if pkg.release else pkg.version,
                    status=status,
                    risk=risk,
                    rhel_package=mapping.rhel_package,
                    rhel_version=mapping.rhel_version,
                    notes=mapping.notes,
                )
            )
        else:
            risk = _guess_risk_for_unknown(pkg.name)
            results.append(
                PackageResult(
                    name=pkg.name,
                    installed_version=f"{pkg.version}-{pkg.release}" if pkg.release else pkg.version,
                    status=MappingStatus.UNKNOWN,
                    risk=risk,
                    notes="Not in mapping database — review manually. Common base packages often have a direct RHEL equivalent.",
                )
            )

    results.sort(key=lambda r: (
        {RiskLevel.RED: 0, RiskLevel.YELLOW: 1, RiskLevel.GRAY: 2, RiskLevel.GREEN: 3}[r.risk],
        r.name,
    ))
    return results


def _guess_risk_for_unknown(package_name: str) -> RiskLevel:
    amazon_prefixes = ("amazon-", "amzn-", "aws-", "ec2-")
    if any(package_name.startswith(p) for p in amazon_prefixes):
        return RiskLevel.RED
    return RiskLevel.GRAY


def _analyze_runtimes(
    inventory: Inventory, mappings: dict[str, list[RuntimeAvailability]]
) -> list[RuntimeResult]:
    results: list[RuntimeResult] = []

    runtime_checks = [
        ("java", inventory.runtimes.java),
        ("python", inventory.runtimes.python),
        ("nodejs", inventory.runtimes.nodejs),
        ("ruby", inventory.runtimes.ruby),
        ("go", inventory.runtimes.go),
        ("php", inventory.runtimes.php),
        ("dotnet", inventory.runtimes.dotnet),
        ("perl", inventory.runtimes.perl),
    ]

    for runtime_key, entries in runtime_checks:
        if not entries:
            continue

        available = mappings.get(runtime_key, [])
        available_versions = [a.version for a in available if a.version]

        for entry in entries:
            installed_version = _normalize_version(entry.version)
            if not installed_version or installed_version == "unknown":
                results.append(
                    RuntimeResult(
                        runtime=runtime_key,
                        installed_version=entry.version,
                        available_in_rhel=False,
                        risk=RiskLevel.GRAY,
                        notes="Version could not be determined.",
                    )
                )
                continue

            rhel_versions_available = []
            install_method = ""
            module_stream = ""
            is_available = False

            for avail in available:
                avail_ver = _normalize_version(avail.version) if avail.version else ""
                installed_major = installed_version.split(".")[0]

                rhel_versions_available.append(avail_ver or avail.install_method)

                if _major_minor(installed_version) == _major_minor(avail_ver):
                    is_available = True
                    install_method = avail.install_method
                    module_stream = avail.module_stream

            if not is_available:
                for avail in available:
                    avail_ver = _normalize_version(avail.version) if avail.version else ""
                    if avail_ver and installed_version.split(".")[0] == avail_ver.split(".")[0]:
                        is_available = True
                        install_method = avail.install_method
                        module_stream = avail.module_stream
                        break

            if is_available:
                risk = RiskLevel.GREEN
                notes = f"Version {installed_version} compatible. Install via: {install_method}"
            else:
                risk = RiskLevel.YELLOW
                closest = rhel_versions_available[-1] if rhel_versions_available else "none"
                notes = (
                    f"Installed version {installed_version} not directly available. "
                    f"Closest RHEL version: {closest}. "
                    f"Available: {', '.join(rhel_versions_available)}"
                )

            results.append(
                RuntimeResult(
                    runtime=runtime_key,
                    installed_version=installed_version,
                    available_in_rhel=is_available,
                    rhel_versions=rhel_versions_available,
                    install_method=install_method,
                    module_stream=module_stream,
                    risk=risk,
                    notes=notes,
                )
            )

    return results


def _build_summary(
    packages: list[PackageResult], runtimes: list[RuntimeResult]
) -> MigrationSummary:
    summary = MigrationSummary(
        total_packages=len(packages),
        total_runtimes=len(runtimes),
    )
    for pkg in packages:
        match pkg.status:
            case MappingStatus.DIRECT:
                summary.direct_match += 1
            case MappingStatus.RENAMED:
                summary.renamed += 1
            case MappingStatus.REPLACED:
                summary.replaced += 1
            case MappingStatus.REMOVED:
                summary.removed += 1
            case MappingStatus.MANUAL:
                summary.manual += 1
            case MappingStatus.UNKNOWN:
                summary.unknown += 1

    for rt in runtimes:
        if rt.available_in_rhel:
            summary.runtimes_available += 1
        else:
            summary.runtimes_unavailable += 1

    return summary
