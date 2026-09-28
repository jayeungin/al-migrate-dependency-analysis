from __future__ import annotations

from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


class MappingStatus(str, Enum):
    DIRECT = "direct"
    RENAMED = "renamed"
    REPLACED = "replaced"
    REMOVED = "removed"
    MANUAL = "manual"
    UNKNOWN = "unknown"


class RiskLevel(str, Enum):
    GREEN = "green"
    YELLOW = "yellow"
    RED = "red"
    GRAY = "gray"


# --- Inventory models (input from discover.sh) ---


class OSInfo(BaseModel):
    name: str = "unknown"
    version: str = "unknown"
    id: str = "unknown"
    al_version: str = "unknown"
    arch: str = "unknown"
    kernel: str = "unknown"
    hostname: str = "unknown"


class InstalledPackage(BaseModel):
    name: str
    version: str = ""
    release: str = ""
    arch: str = ""
    vendor: str = ""


class Repository(BaseModel):
    id: str
    name: str = ""


class Service(BaseModel):
    name: str
    state: str = ""


class RuntimeEntry(BaseModel):
    version: str = "unknown"
    path: str = ""
    home: str = ""
    source: str = ""
    command: str = ""
    name: str = ""


class PipPackage(BaseModel):
    name: str
    version: str = ""


class NodeGlobalPackage(BaseModel):
    name: str


class RubyGem(BaseModel):
    name: str


class PhpModule(BaseModel):
    name: str


class DotnetSdk(BaseModel):
    version: str


class RuntimeInventory(BaseModel):
    java: list[RuntimeEntry] = Field(default_factory=list)
    python: list[RuntimeEntry] = Field(default_factory=list)
    python_pip_packages: list[PipPackage] = Field(default_factory=list)
    nodejs: list[RuntimeEntry] = Field(default_factory=list)
    nodejs_global_packages: list[NodeGlobalPackage] = Field(default_factory=list)
    ruby: list[RuntimeEntry] = Field(default_factory=list)
    ruby_gems: list[RubyGem] = Field(default_factory=list)
    go: list[RuntimeEntry] = Field(default_factory=list)
    php: list[RuntimeEntry] = Field(default_factory=list)
    php_modules: list[PhpModule] = Field(default_factory=list)
    dotnet: list[RuntimeEntry] = Field(default_factory=list)
    dotnet_sdks: list[DotnetSdk] = Field(default_factory=list)
    perl: list[RuntimeEntry] = Field(default_factory=list)


class NetworkListener(BaseModel):
    address: str = ""
    port: str = ""
    process: str = ""


class KernelModule(BaseModel):
    name: str
    size: str = ""


class Inventory(BaseModel):
    schema_version: str = "1.0"
    generated_at: str = ""
    script_version: str = ""
    os: OSInfo = Field(default_factory=OSInfo)
    packages: list[InstalledPackage] = Field(default_factory=list)
    repositories: list[Repository] = Field(default_factory=list)
    services_running: list[Service] = Field(default_factory=list)
    services_enabled: list[Service] = Field(default_factory=list)
    runtimes: RuntimeInventory = Field(default_factory=RuntimeInventory)
    kernel_modules: list[KernelModule] = Field(default_factory=list)
    network_listeners: list[NetworkListener] = Field(default_factory=list)


# --- Mapping models ---


class PackageMapping(BaseModel):
    rhel_package: Optional[str] = None
    status: MappingStatus = MappingStatus.UNKNOWN
    rhel_version: Optional[str] = None
    notes: str = ""


class RuntimeAvailability(BaseModel):
    version: str = ""
    install_method: str = ""
    module_stream: str = ""
    notes: str = ""


# --- Report models (output) ---


class PackageResult(BaseModel):
    name: str
    installed_version: str = ""
    status: MappingStatus
    risk: RiskLevel
    rhel_package: Optional[str] = None
    rhel_version: Optional[str] = None
    notes: str = ""


class RuntimeResult(BaseModel):
    runtime: str
    installed_version: str
    available_in_rhel: bool = False
    rhel_versions: list[str] = Field(default_factory=list)
    install_method: str = ""
    module_stream: str = ""
    risk: RiskLevel = RiskLevel.GRAY
    notes: str = ""


class MigrationSummary(BaseModel):
    total_packages: int = 0
    direct_match: int = 0
    renamed: int = 0
    replaced: int = 0
    removed: int = 0
    manual: int = 0
    unknown: int = 0
    total_runtimes: int = 0
    runtimes_available: int = 0
    runtimes_unavailable: int = 0


class MigrationReport(BaseModel):
    report_id: str = ""
    source_os: str = ""
    target_os: str = ""
    generated_at: str = ""
    inventory_generated_at: str = ""
    hostname: str = ""
    summary: MigrationSummary = Field(default_factory=MigrationSummary)
    packages: list[PackageResult] = Field(default_factory=list)
    runtimes: list[RuntimeResult] = Field(default_factory=list)
    services: list[Service] = Field(default_factory=list)
    network_listeners: list[NetworkListener] = Field(default_factory=list)
